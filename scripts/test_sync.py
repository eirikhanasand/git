"""Exercise the sync's fail-closed boundaries without contacting either server."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('sync-to-ovh.sh')
DOCKER = '''#!/usr/bin/env python3
import os,sys
from pathlib import Path
a=' '.join(sys.argv[1:])
with open(os.environ['CALLS'],'a') as f: f.write('docker '+a+'\\n')
if sys.argv[1]=='inspect': print(os.environ.get('APP_RUNNING','false'))
elif sys.argv[1]=='run': sys.exit(int(os.environ.get('COPY_EXIT','0')))
elif 'pg_is_in_recovery' in a: print(os.environ.get('RECOVERY','t'))
elif 'pg_stat_wal_receiver' in a: print(os.environ.get('RECEIVER','streaming'))
elif 'pg_current_wal_lsn' in a: print('1/ABC')
elif 'pg_last_wal_replay_lsn' in a: print('t')
else: sys.exit(88)
'''
SSH = '''#!/usr/bin/env python3
import os,sys
os.execvp('bash',['bash','-c',sys.argv[-1]])
'''

class SyncTests(unittest.TestCase):
    def run_sync(self, **overrides):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/'calls').touch()
            for name,body in [('ssh',SSH),('docker',DOCKER)]:
                p=root/name; p.write_text(body); p.chmod(0o755)
            env={**os.environ,'PATH':tmp+':'+os.environ['PATH'],
                 'LOG':tmp+'/log','LOCK':tmp+'/lock','LOCAL_GIT_DIR':tmp,
                 'CALLS':tmp+'/calls',**overrides}
            result=subprocess.run(['bash',str(SCRIPT)],env=env,timeout=10)
            return result.returncode,(root/'log').read_text(),(root/'calls').read_text()

    def test_success_only_copies_files_and_checks_replication(self):
        code,log,calls=self.run_sync()
        self.assertEqual(code,0,log)
        self.assertIn('sync ok; standby replayed 1/ABC',log)
        self.assertEqual(calls.count('docker run '),2)
        for forbidden in ('pg_dump','pg_restore','dropdb','createdb','compose','doctor'):
            self.assertNotIn(forbidden,calls)

    def test_promoted_standby_is_never_overwritten(self):
        code,log,calls=self.run_sync(RECOVERY='f')
        self.assertNotEqual(code,0)
        self.assertIn('promoted',log)
        self.assertNotIn('docker run ',calls)

    def test_running_application_blocks_copy(self):
        code,log,calls=self.run_sync(APP_RUNNING='true')
        self.assertNotEqual(code,0)
        self.assertIn('must remain stopped',log)
        self.assertNotIn('docker run ',calls)

    def test_disconnected_replication_blocks_copy(self):
        code,log,calls=self.run_sync(RECEIVER='')
        self.assertNotEqual(code,0)
        self.assertIn('not streaming',log)
        self.assertNotIn('docker run ',calls)

    def test_copy_failure_does_not_start_standby(self):
        code,log,calls=self.run_sync(COPY_EXIT='23')
        self.assertEqual(code,23)
        self.assertIn('standby remains fenced',log)
        self.assertNotIn('compose',calls)
        self.assertNotIn('sync ok',log)

if __name__=='__main__': unittest.main()
