"""Quiet-pass plumbing. Smoke discards all elapsed values and raw output."""
import argparse
import datetime
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile

class Pass:
    def __init__(self, here, configure=None):
        self.here = Path(here).resolve().parent
        self.repo = self.here.parent
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--smoke', action='store_true')
        parser.add_argument('--runs', type=int, default=5)
        parser.add_argument('--before')
        parser.add_argument('--after')
        parser.add_argument('--build-dir', type=Path, default=self.here / 'build/quiet')
        parser.add_argument('--output', type=Path)
        if configure: configure(parser)
        self.args = parser.parse_args()
        if self.args.runs < 1: parser.error('--runs must be positive')
        self.smoke = self.args.smoke
        self.runs = 1 if self.smoke else self.args.runs
        self.build = self.args.build_dir.resolve() / ('smoke' if self.smoke else 'full')
        self.out = (self.args.output or self.here / 'results' / datetime.date.today().isoformat()).resolve()
        self.build.mkdir(parents=True, exist_ok=True)
        self.out.mkdir(parents=True, exist_ok=True)
        self.env = os.environ.copy()
        self.env.update(PYTHONDONTWRITEBYTECODE='1', GIT_CONFIG_NOSYSTEM='1',
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0',
                        GIT_CONFIG_COUNT='2', GIT_CONFIG_KEY_0='gc.auto', GIT_CONFIG_VALUE_0='0',
                        GIT_CONFIG_KEY_1='maintenance.auto', GIT_CONFIG_VALUE_1='false')
        for key in ('GIT_DIR','GIT_WORK_TREE','RELIC_BENCH_REPEAT'): self.env.pop(key, None)
        pins = json.loads((self.here / 'revisions.json').read_text())
        self.revisions = {side: self.git('rev-parse', getattr(self.args, side) or pins[side]) for side in ('before','after')}
        self.rows = []
        self.complete = False
        self.machine = {'os': platform.system(), 'release': platform.release(),
                        'architecture': platform.machine(), 'cpu_count': os.cpu_count(),
                        'python': platform.python_version(), 'tools': {}}
        if sys.platform == 'darwin':
            for key in ('hw.model','hw.memsize','machdep.cpu.brand_string'):
                self.machine[key] = self.run(['sysctl','-n',key]).strip()
        for name, argv in {'zig':['zig','version'],'git':['git','--version'], 'go':['go','version'],
                           'rust':['rustc','--version'],'cargo':['cargo','--version'], 'cc':['cc','--version']}.items():
            if shutil.which(argv[0]): self.machine['tools'][name] = self.run(argv).splitlines()[0]
        self.metadata = pins
        self.save()
    def git(self, *args):
        return subprocess.check_output(['git','-C',str(self.repo),*args],text=True).strip()
    def clean(self, value):
        if isinstance(value, dict): return {k:self.clean(v) for k,v in value.items()}
        if isinstance(value, (list,tuple)): return [self.clean(v) for v in value]
        if not isinstance(value,str): return value
        for path, label in sorted(((self.build,'<build>'),(self.out,'<results>'),(self.repo,'<repo>'),(Path.home(),'<home>')), key=lambda p:-len(str(p[0]))):
            value = value.replace(str(path),label)
        return re.sub(r'/(?:private/)?(?:tmp|var/folders)/[^\s"\t]+','<scratch>',value)
    def run(self, argv, cwd=None, env=None, timeout=1800):
        proc = subprocess.run(list(map(str,argv)),cwd=cwd,env=env or self.env,
                              capture_output=True,text=True,timeout=timeout)
        if proc.returncode:
            # Do not persist output from a failed smoke either: it can contain timings.
            raise RuntimeError(self.clean(f'command failed (exit {proc.returncode}): '+str(argv)+'\n'+proc.stderr[-5000:]))
        return proc.stdout + proc.stderr
    def snapshot(self, side):
        target = self.build / 'sources' / side
        marker = target / '.bench-revision'
        if target.exists() and (not marker.exists() or marker.read_text() != self.revisions[side]):
            shutil.rmtree(target)
        target.mkdir(parents=True,exist_ok=True)
        data = subprocess.check_output(['git','-C',str(self.repo),'archive',self.revisions[side]])
        with tarfile.open(fileobj=io.BytesIO(data)) as archive: archive.extractall(target,filter='data')
        shutil.copytree(self.here,target/'bench',dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('build','results','zig-out','.zig-cache','zig-pkg',
                                                     '__pycache__','target','node_modules'))
        wrapper = self.repo / 'bench_regressions.zig'
        if wrapper.exists(): shutil.copyfile(wrapper,target/wrapper.name)
        marker.write_text(self.revisions[side])
        return target
    def zig(self, source, sub='bench', *steps):
        install = source / sub / 'zig-out'
        self.run(['zig','build','-j1','-Doptimize=ReleaseFast',
                  '-Dsmoke='+str(self.smoke).lower(),*(['-Dsnapshot=true'] if sub == 'bench' else []),*steps],cwd=source/sub)
        return install / 'bin'
    def point(self, workload, side, argv, round, cwd=None, env=None, prepare=None, check=None):
        print(f'  {workload}: {side} ({round+1}/{self.runs})',flush=True)
        if prepare: prepare()
        output = self.run(argv,cwd=cwd,env=env)
        evidence = check(output) if check else None
        row = {'workload':workload,'side':side,'round':round+1,'status':'passed'}
        if evidence is not None: row['correctness'] = evidence
        if not self.smoke:
            row['output'] = output
            metrics = []
            for line in output.splitlines():
                fields = line.split('\t')
                if len(fields) == 5:
                    try: value = float(fields[3])
                    except ValueError: value = fields[3]
                    metrics.append({'reported_side':fields[0], 'workload':fields[1],
                                    'metric':fields[2], 'value':value, 'unit':fields[4]})
            if metrics: row['metrics'] = metrics
        self.rows.append(row)
        self.save()
        return output
    def interleave(self, workload, commands, **kwargs):
        # Same order on every round: A, B, comparisons, A, B, comparisons ...
        if not self.smoke:
            for side, argv in commands:
                if kwargs.get('prepare'): kwargs['prepare']()
                output = self.run(argv,cwd=kwargs.get('cwd'),env=kwargs.get('env'))
                if kwargs.get('check'): kwargs['check'](output)
        for round in range(self.runs):
            for side, argv in commands: self.point(workload,side,argv,round,**kwargs)
    def save(self, failure=None):
        report = self.clean({'mode':'smoke' if self.smoke else 'benchmark', 'revisions':self.revisions,
                 'baseline_note':self.metadata.get('baseline_note','Last first-parent main commit before the midnight cutoff.'),
                 'machine':self.machine, 'harness_commit':self.git('rev-parse','HEAD'),
                 'harness_dirty':bool(self.git('status','--porcelain','--untracked-files=no')),
                 'order':'A (before), B (after), comparisons; repeated per workload',
                 'samples':self.rows, 'failure':failure,
                 'complete':self.complete, 'timings_recorded':not self.smoke})
        name = 'smoke' if self.smoke else 'report'
        (self.out/(name+'.json')).write_text(json.dumps(report,indent=2)+'\n')
        lines = ['# '+('Smoke correctness' if self.smoke else 'Quiet benchmark'),'',
                 'Before: `'+self.revisions['before']+'`; after: `'+self.revisions['after']+'`.','',
                 report['baseline_note'],'', 'Machine: '+json.dumps(report['machine']), '',
                 'Order: '+report['order']+'.','',
                 'No timings recorded. Tiny harness checks only.' if self.smoke else 'Individual samples follow; preparation and compilation are outside measurements.', '',
                 '| Workload | Side | Round | Status |','|---|---|---:|---|']
        for row in report['samples']:
            lines.append(f"| {row['workload']} | {row['side']} | {row['round']} | {row['status']} |")
        if not self.smoke:
            for row in report['samples']:
                lines += ['', f"{row['workload']} / {row['side']} / round {row['round']}", '```text',row.get('output',json.dumps(row.get('measurements',{}))).rstrip(),'```','']
        if failure: lines += ['', 'Failure: '+str(report['failure'])]
        (self.out/(name+'.md')).write_text('\n'.join(lines)+'\n')
    def finish(self):
        self.complete = True
        self.save()
        print(f"{'Smoke passed; no timings recorded' if self.smoke else 'Pass complete'}: {self.out}",flush=True)

def tsv(output):
    rows = [line.split('\t') for line in output.splitlines() if '\t' in line]
    if not rows or any(len(row)!=5 for row in rows): raise ValueError('invalid five-column output')
    if any(row[3] == 'ERROR' for row in rows): raise ValueError('workload reported ERROR')
    return {'rows':len(rows),'unavailable':sum(row[3] in ('n/a','unavailable') for row in rows),
            'counts':{row[2]:row[3] for row in rows if row[4] in ('count','bytes') and row[2] not in ('peak_rss','rss')}}
