"""Independent local Keccak verification, using a separate pure-Python Keccak implementation."""
import json
from pathlib import Path
from keccak_reference import k256
p=Path(__file__).resolve().parent.parent
manifest=json.loads((p/'results/manifest.json').read_text())
def k(data):
    return k256(data)
raw=(p/'results/config.canonical.json').read_bytes()
computed='0x'+k(raw).hex()
assert computed==manifest['fullConfigHash']
c=json.loads(raw)
dep=c['deployment']['evm'];sender=bytes.fromhex(dep['deployer'][2:]);factory=bytes.fromhex(dep['factory'][2:])
proxy_hash=bytes.fromhex('21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f')
rows=[]
for name,e in dep['contracts'].items():
    if e['salt'] is None:continue
    salt=bytes.fromhex(e['salt'][2:])
    guarded=k(bytes(12)+sender+salt)
    proxy=k(b'\xff'+factory+guarded+proxy_hash)[12:]
    derived='0x'+k(bytes.fromhex('d694')+proxy+b'\x01')[12:].hex()
    assert derived==e['address'].lower()
    rows.append({'name':name,'address':derived,'matches':True})
report={'method':'Independent pure-Python Keccak-256; offline review reference only','configHash':computed,'matches':True,'utf8Bytes':len(raw),'registry':rows,'caveat':'No RPC, key control, runtime code or deployment verification was performed.'}
(p/'results/crypto-independent.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'hashMatches':True,'registryMatches':len(rows),'configHash':computed}))
