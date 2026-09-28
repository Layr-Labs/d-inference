"""Versioned evidence primitives shared by independent namespace validators."""
import hashlib
import json
import math
import re

WIDTH = {'float16':2,'bfloat16':2,'float32':4,'uint32':4,'int32':4,'uint8':1}
FLOATS = ('float16','bfloat16','float32')


def require(value,message):
    if not value:raise ValueError(message)


def integer(value,minimum=0,maximum=2**63-1):
    require(type(value)is int and minimum<=value<=maximum,'Invalid bounded integer')
    return value


def sha(value):
    require(type(value)is str and re.fullmatch('[0-9a-f]{64}',value) is not None,'Invalid SHA256')
    return value


def digest(data):return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False).encode()


def exact(a,b,message):require(canonical(a)==canonical(b),message)


def parse(data):
    def pairs(items):
        result={}
        for key,value in items:
            require(key not in result,'Duplicate JSON key');result[key]=value
        return result
    def floating(value):
        number=float(value);require(math.isfinite(number),'Nonfinite JSON number');return number
    def invalid(value):raise ValueError('Nonfinite JSON constant')
    return json.loads(data,object_pairs_hook=pairs,parse_float=floating,parse_constant=invalid,
                      parse_int=lambda value:-0.0 if value=='-0' else int(value))


def shape_bytes(shape,dtype,allow_empty_conv=False):
    require(isinstance(shape,list) and 1<=len(shape)<=4 and dtype in WIDTH,'Invalid shape/dtype')
    for index,value in enumerate(shape):
        integer(value,0 if allow_empty_conv and index==1 else 1,2**31-1)
    count=math.prod(shape)*WIDTH[dtype]
    return integer(count,0,6*1024**3)


def flags(record,**values):
    for key,value in values.items():require(type(record.get(key))is bool and record[key]is value,'Wrong flag: '+key)


def envelope(record,kind,rank,epoch):
    require(isinstance(record,dict) and record.get('kind')==kind,'Wrong evidence namespace')
    for key,value in [('schemaVersion',1),('rank',rank),('worldSize',2)]:
        require(type(record.get(key))is int and record[key]==value,'Wrong integer identity: '+key)
    for key,value in [('epoch',epoch),('transport','loopback-test'),('backend','ring')]:
        require(record.get(key)==value,'Wrong transport/cohort identity: '+key)
