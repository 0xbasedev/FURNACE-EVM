"""Offline review Keccak-256 reference, checked against empty and abc vectors. Not production cryptographic software."""
import json
from pathlib import Path
MASK = (1 << 64) - 1
RC = [0x0000000000000001,0x0000000000008082,0x800000000000808a,0x8000000080008000,
      0x000000000000808b,0x0000000080000001,0x8000000080008081,0x8000000000008009,
      0x000000000000008a,0x0000000000000088,0x0000000080008009,0x000000008000000a,
      0x000000008000808b,0x800000000000008b,0x8000000000008089,0x8000000000008003,
      0x8000000000008002,0x8000000000000080,0x000000000000800a,0x800000008000000a,
      0x8000000080008081,0x8000000000008080,0x0000000080000001,0x8000000080008008]
ROT = [[0,36,3,41,18],[1,44,10,45,2],[62,6,43,15,61],[28,55,25,21,56],[27,20,39,8,14]]
def rot(x,n):
    return ((x << n) | (x >> (64-n))) & MASK if n else x

def perm(a):
    for rc in RC:
        c = [a[x]^a[x+5]^a[x+10]^a[x+15]^a[x+20] for x in range(5)]
        d = [c[(x-1)%5]^rot(c[(x+1)%5],1) for x in range(5)]
        a = [a[x+5*y]^d[x] for y in range(5) for x in range(5)]
        b = [0]*25
        for y in range(5):
            for x in range(5):
                b[y+5*((2*x+3*y)%5)] = rot(a[x+5*y],ROT[x][y])
        a = [(b[x+5*y]^((~b[(x+1)%5+5*y])&b[(x+2)%5+5*y]))&MASK for y in range(5) for x in range(5)]
        a[0] ^= rc
    return a

def k256(data):
    rate=136
    padlen=rate-len(data)%rate
    padding=bytearray(padlen)
    padding[0]=1
    padding[-1]|=128
    msg=data+bytes(padding)
    a=[0]*25
    for pos in range(0,len(msg),rate):
        block=msg[pos:pos+rate]
        for i in range(rate//8):
            a[i]^=int.from_bytes(block[i*8:i*8+8],'little')
        a=perm(a)
    return b''.join(x.to_bytes(8,'little') for x in a)[:32]

assert k256(b'').hex()=='c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470'
assert k256(b'abc').hex()=='4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45'
