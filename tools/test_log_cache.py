"""Non-destructive regression: only creates files in a unique build/temp directory."""
from pathlib import Path
import os, subprocess, tempfile
root=Path(__file__).resolve().parents[2]
sb=Path(tempfile.mkdtemp(prefix='cache208_',dir=root/'build'))
logs=sb/'logs';logs.mkdir()
env=os.environ.copy();env.update(MODDIR=(root/'repo').as_posix(),CHARGELOG_DIR=logs.as_posix(),SYSFS_ROOT=(sb/'sys').as_posix())
bb=str(root/'tools/dl/busybox.exe');script=str(root/'repo/monitor.sh')
checks=0
def run(*args,**extra):
 e=dict(env);e.update(extra)
 p=subprocess.run([bb,'sh',script,*args],env=e,capture_output=True,check=True)
 return dict(x.split('=',1) for x in p.stdout.decode().splitlines() if '=' in x)
def check(v,msg):
 global checks
 assert v,msg
 checks+=1;print('PASS',msg)
def core(d):return {k:v for k,v in d.items() if k.startswith('log.')}
f=logs/'20251001-100000.log'
f.write_text('#start=10\n10,40,350,3000000,4500000,1000,Charging,13500000\n#end=20\n',encoding='utf8')
g=logs/'20251002-100000.log';g.touch()
a=run('--logs');b=run('--logs');c=run('--logs',MONITOR_NO_CACHE='1');d=run('--logs',MONITOR_NO_AWK='1')
check(a['log_cache']=='0/2','cold cache scans both files')
check(b['log_cache']=='2/0','warm cache skips both files')
check(core(a)==core(b)==core(c)==core(d),'cache/legacy/shell agree including empty newest file')
with f.open('a',encoding='utf8') as out:out.write('30,41,370,4000000,4500000,2000,Charging,18000000\n')
a=run('--logs');check(a['log_cache']=='1/1' and a['log.1.samples']=='2','append invalidates only changed file')
f.write_text('#start=50\n',encoding='utf8');a=run('--logs');check(a['log.1.samples']=='0' and a['log.1.start']=='50','truncate invalidates cache')
cache=logs/'.webui-summary-v1';cache.write_text('broken\n',encoding='utf8');a=run('--logs');check(a['log_cache']=='0/2','corrupt cache regenerates')
f.write_text('#start=51\n',encoding='utf8');a=run('--logs');check(a['log.1.start']=='51','same-length rewrite invalidates cache within one second')
cache.unlink();cache.mkdir();a=run('--logs');check(a['log.list_count']=='2' and core(a)==core(run('--logs',MONITOR_NO_CACHE='1')),'unwritable cache falls back without losing sessions')
cache.rmdir()
f.write_text('#start=10\n'+''.join(f'{i+10},40,350,3000000,4500000,1000,Charging,13500000\n' for i in range(4500))+'#end=99999\n',encoding='utf8')
a=run('--log',f.name);b=run('--log',f.name,MONITOR_NO_AWK='1')
check(a==b,'awk and shell detail output agree beyond 4000 samples')
check(a['session.count']=='4000' and a['session.end']=='99999','point cap preserves final end metadata')
f.unlink();a=run('--logs');check(a['log.list_count']=='1' and a['log.0.name']==g.name,'deleted file absent despite cached row')
print(f'{checks}/{checks} passed; fixtures: {sb}')
