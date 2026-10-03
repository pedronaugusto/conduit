"""Run the prepared conduit workloads on pinned package sources."""
from pathlib import Path
import os
import sys
from quiet_common import Pass, tsv

def agreeing(row):
    """`tsv`, and every side's count and byte rows equal to the first side's."""
    first = {}
    def check(output):
        evidence = tsv(output)
        if evidence['counts']:
            if first and evidence['counts'] != first:
                raise ValueError(f'{row}: sides disagree: {first} != {evidence["counts"]}')
            first.update(evidence['counts'])
        return evidence
    return check

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
        p.setup_run([p.here/'run.sh'],env=env)
        for asset in ('cargo/release/conduit-rust-bench','go-bench','c-bench','venv/bin/python','data'):
            p.prepared.require(tools/asset)
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
                        if workload=='pty_spawn' and not p.smoke:count={'python':20}.get(tool,n)
                        points.append((tool,[*argv,workload,count,fixture]))
            p.interleave(workload,points,check=tsv)
        # The rest of the public API: (row, workload, fixture, full count, sides
        # that have the operation, per-side counts). Each side checks its own
        # result; rows in count/bytes units must agree across sides.
        every = ('rust','go','c','python')
        for row, workload, fixture, full, tools_with, counts in (
            ('exchange-1k','exchange','pty-1k.bin',500,every,{}),
            ('exchange-1m','exchange','lines-1m.bin',50,every,{}),
            ('exchange-64m','exchange','pty-64m.bin',3,every,{}),
            ('collect-1m','collect','lines-1m.bin',50,every,{}),
            ('collect-64m','collect','pty-64m.bin',3,every,{}),
            ('input_writer-1m','input_writer','lines-1m.bin',10,every,{}),
            ('read_available','read_available','arg-1k.txt',500,('go','c','python'),{}),
            ('try_wait','try_wait','arg-1k.txt',100000,('rust','c','python'),{}),
            ('reaper_wait','reaper_wait','arg-1k.txt',500,every,{}),
            ('expect','expect','pty-1k.bin',2000,('python',),{}),
            ('proxy-1m','proxy','lines-1m.bin',10,every,{}),
            ('proxy-16m','proxy','lines-16m.bin',1,every,{}),
            ('shell_spawn','shell_spawn','arg-1k.txt',200,every,{'python':20}),
            ('pty_open','pty_open','arg-1k.txt',2000,every,{}),
            ('tty_ops','tty_ops','arg-1k.txt',2000,every,{}),
            ('find_program','find_program','arg-1k.txt',5000,('go','python'),{}),
            ('environ','environ','arg-1k.txt',20000,('rust','go','python'),{}),
            ('process_identity','process_identity','arg-1k.txt',20000,('go','c','python'),{}),
            ('end_recorded','end_recorded','arg-1k.txt',200,(),{}),
        ):
            if p.smoke: fixture = 'arg-1k.txt' if fixture=='arg-1k.txt' else 'pty-1k.bin'
            points=[(s,[binary[s]/'conduit-bench',workload,1 if p.smoke else full,d/fixture]) for s in source]
            points+=[(tool,[*commands[tool],workload,1 if p.smoke else counts.get(tool,full),d/fixture]) for tool in tools_with]
            p.interleave(row,points,check=agreeing(row))
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
