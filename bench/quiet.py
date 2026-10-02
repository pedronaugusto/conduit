"""Run the prepared conduit workloads on pinned package sources."""
from pathlib import Path
import os
import sys
from quiet_common import Pass, tsv

def main():
    p = Pass(__file__)
    try:
        source = {s:p.snapshot(s) for s in ('before','after')}
        binary = {s:p.zig(source[s]) for s in source}
        tools = p.here / 'build/tools'
        env = p.env.copy()
        env.update(BENCH_BUILD_ONLY='1',BENCH_BUILD_DIR=str(tools),PYTHON=sys.executable)
        if p.smoke: env['SMOKE']='1'
        else: env.pop('SMOKE',None)
        p.run([p.here/'run.sh'],env=env)
        if p.smoke: p.env['SMOKE']='1'
        d = tools/'data'
        commands = {'rust':[tools/'cargo/release/conduit-rust-bench'], 'go':[tools/'go-bench'],
                    'c':[tools/'c-bench'], 'python':[tools/'venv/bin/python',p.here/'src/python/bench.py']}
        for workload in ('spawn_wait','spawn_collect','pty_spawn','pty_throughput','wait_timeout','tree_kill','leaf_kill','pty_spawn_child_kill'):
            n = 1 if p.smoke or workload=='pty_throughput' else {'spawn_wait':2000,'spawn_collect':2000,'pty_spawn':500,'wait_timeout':500,'tree_kill':200,'leaf_kill':200,'pty_spawn_child_kill':500}[workload]
            fixture = d / ('pty-1k.bin' if workload.startswith('pty') else 'arg-1k.txt')
            if workload=='pty_throughput' and not p.smoke: fixture=d/'pty-64m.bin'
            points=[(s,[binary[s]/'conduit-bench',workload,n,fixture]) for s in source]
            if workload not in ('leaf_kill','pty_spawn_child_kill'):
                for tool, argv in commands.items():
                    if workload=='wait_timeout' and tool=='rust':continue
                    if tool=='c' and workload.startswith('spawn_'):
                        points.extend([(label,[*argv,verb,n,fixture]) for label,verb in [('c-posix-spawn','posix_'+workload),('c-fork','fork_'+workload.removeprefix('spawn_'))]])
                    else:
                        count = n
                        if workload=='pty_spawn' and not p.smoke:count={'rust':50,'python':20}.get(tool,n)
                        points.append((tool,[*argv,workload,count,fixture]))
            p.interleave(workload,points,check=tsv)
        def claims(output):
            rows=[x.split('\t') for x in output.splitlines() if '\t' in x]
            if len(rows)<7 or any(len(x)!=4 for x in rows): raise ValueError('missing lifecycle claim rows')
            return {'claims_exercised':len(rows)}
        p.interleave('lifecycle-claims',[(s,[binary[s]/'lifecycle-claims','--quiet-machine']) for s in source],check=claims)
        p.interleave('orphans',[(s,[binary[s]/'orphans-cost']) for s in source],check=lambda out:{'unavailable':sys.platform!='linux'})
        p.finish()
    except Exception as error:
        p.save(str(error));raise

if __name__=='__main__':main()
