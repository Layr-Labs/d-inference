"""Small CPU fixtures only: raw bytes, semantic ownership and metric corruption."""
import copy,importlib.util,json,struct,tempfile,unittest
from pathlib import Path
from qwen_gdn_input_audit import *

TEXT=dict(hidden_size=64,linear_num_key_heads=2,linear_num_value_heads=2,
    linear_key_head_dim=32,linear_value_head_dim=32,vocab_size=8,rms_norm_eps=1e-6)


def cap(shape,values,dtype):return dict(shape=shape,dtype=dtype,values=values,logicalBytesSHA256=digest(logical_bytes(values,dtype)))


def fixture(dtype='float32'):
    width=260;m=2;full=[(1+i%64)/8 for i in range(m*width)]
    source=[]
    for name,rows in [('qkv',192),('z',64),('b',2),('a',2)]:
        source.append(dict(name='in_proj_'+name,modulePath='language_model.model.layers.0.linear_attn.in_proj_'+name,
            inputWidth=64,outputRows=rows,bits=4,groupSize=64,mode='affine'))
    record=dict(chunkSize=m,sourceProjections=source,sourceProjectionsSHA256=digest(canonical(source)),
        normalizedInput=cap([1,m,64],[1.0]*(m*64),dtype),firstLogits=cap([1,8],list(map(float,range(8))),dtype),
        firstLogitArgmaxToken=7,inputNormPath='language_model.model.layers.0.input_layernorm',inputNormEpsilon=1e-6)
    def projection(rank):
        comps=components(TEXT,rank);values=[]
        for row in range(m):
            for comp in comps:
                lo,hi=comp['sourceRows'];values.extend(full[row*width+lo:row*width+hi])
        choices=selections(TEXT,rank)
        return dict(output=cap([1,m,260 if rank is None else 130],values,dtype),components=comps,
            selections=choices,selectionSHA256=digest(canonical(choices)),**({} if rank is None else dict(rank=rank)))
    record.update(full=projection(None),ranks=[projection(0),projection(1)])
    def identity(shape,dt):return dict(shape=shape,dtype=dt,logicalBytesSHA256='0'*64)
    record['inputNormWeight']=identity([64],dtype)
    for source in record['sourceProjections']:
        source.update(weight=identity([source['outputRows'],8],'uint32'),scales=identity([source['outputRows'],1],dtype),biases=identity([source['outputRows'],1],dtype))
    record['sourceProjectionsSHA256']=digest(canonical(record['sourceProjections']))
    for rank,item in [(None,record['full']),*enumerate(record['ranks'])]:
        width=260 if rank is None else 130
        item.update(fusedWeight=identity([width,8],'uint32'),fusedScales=identity([width,1],dtype),fusedBiases=identity([width,1],dtype))
    return record


def write_checkpoint(root,record):
    header={};payload=bytearray();raw_tensors={}
    def add(name,shape,dtype,data):
        header[name]=dict(shape=shape,dtype=dtype,data_offsets=[len(payload),len(payload)+len(data)])
        payload.extend(data);raw_tensors[name]=data
        return dict(shape=shape,dtype={'U32':'uint32','BF16':'bfloat16'}[dtype],logicalBytesSHA256=digest(data))
    for n,projection in enumerate(record['sourceProjections']):
        rows=projection['outputRows'];path=projection['modulePath']
        for suffix,cols,dtype in [('weight',8,'U32'),('scales',1,'BF16'),('biases',1,'BF16')]:
            data=b''.join(struct.pack('<I',100000*n+row*8+col) if dtype=='U32' else struct.pack('<H',0x3f80+(row+n)%32)
                for row in range(rows) for col in range(cols))
            projection[suffix]=add(path+'.'+suffix,[rows,cols],dtype,data)
    norm='language_model.model.layers.0.input_layernorm.weight'
    record['inputNormWeight']=add(norm,[64],'BF16',struct.pack('<H',0x3f80)*64)
    record['sourceProjectionsSHA256']=digest(canonical(record['sourceProjections']))
    for rank,p in [(None,record['full']),*enumerate(record['ranks'])]:
        for suffix,key,cols,bpe in [('weight','fusedWeight',8,4),('scales','fusedScales',1,2),('biases','fusedBiases',1,2)]:
            fused=b''
            for source,choice in zip(record['sourceProjections'],selections(TEXT,rank)):
                raw=raw_tensors[source['modulePath']+'.'+suffix]
                for lo,hi in choice['ranges']:fused+=raw[lo*cols*bpe:hi*cols*bpe]
            p[key]=dict(shape=[260 if rank is None else 130,cols],dtype='uint32' if bpe==4 else 'bfloat16',logicalBytesSHA256=digest(fused))
    encoded=json.dumps(header,separators=(',',':')).encode();path=root/'model.safetensors'
    path.write_bytes(struct.pack('<Q',len(encoded))+encoded+payload);return path


class RawProjectionTests(unittest.TestCase):
    def test_float32_component_coverage_exact(self):
        a=projection_oracle(fixture(),TEXT)
        self.assertTrue(a['reassembled']['exact']);self.assertEqual(a['reassembled']['comparedValues'],520)
    def test_bf16_one_step_is_localized_to_owned_q(self):
        r=fixture('bfloat16');x=r['ranks'][0]['output'];x['values'][0]+=1/1024
        x['logicalBytesSHA256']=digest(logical_bytes(x['values'],x['dtype']))
        a=projection_oracle(r,TEXT);self.assertEqual(a['reassembled']['differingValues'],1)
        self.assertEqual(a['ranks'][0]['components'][0]['bfloat16Steps']['oneStepDifferences'],1)
        self.assertTrue(all(c['aggregate']['exact'] for c in a['ranks'][1]['components']))
    def test_raw_hash_and_dtype_lies_rejected(self):
        r=fixture();r['normalizedInput']['values'][0]=2.0
        with self.assertRaisesRegex(ValueError,'hash differs'):projection_oracle(r,TEXT)
        r=fixture('bfloat16');r['full']['output']['values'][0]=.1001
        with self.assertRaisesRegex(ValueError,'exactly BF16'):projection_oracle(r,TEXT)
    def test_shifted_component_and_wrong_selection_rejected(self):
        r=fixture();r['ranks'][0]['components'][1]['sourceRows']=[0,32]
        with self.assertRaisesRegex(ValueError,'component layout'):projection_oracle(r,TEXT)
        r=fixture();r['ranks'][0]['selections'][0]['ranges']=[[0,96]]
        r['ranks'][0]['selectionSHA256']=digest(canonical(r['ranks'][0]['selections']))
        with self.assertRaisesRegex(ValueError,'selection differs'):projection_oracle(r,TEXT)
    def test_missing_row_and_wrong_argmax_rejected(self):
        r=fixture();r['firstLogits']['values'].pop()
        with self.assertRaisesRegex(ValueError,'Incomplete'):projection_oracle(r,TEXT)
        r=fixture();r['firstLogitArgmaxToken']=6
        with self.assertRaisesRegex(ValueError,'argmax'):projection_oracle(r,TEXT)
    def test_actual_file_bytes_and_fused_hashes(self):
        with tempfile.TemporaryDirectory() as d:
            r=fixture('bfloat16');p=write_checkpoint(Path(d),r)
            self.assertEqual(len(verify_real_weight_bytes(r,d,TEXT)),10)
            data=bytearray(p.read_bytes());data[-1]^=1;p.write_bytes(data)
            with self.assertRaisesRegex(ValueError,'norm weight'):verify_real_weight_bytes(r,d,TEXT)
    def test_rank_fused_weight_hash_corruption_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            r=fixture();write_checkpoint(Path(d),r);r['ranks'][1]['fusedWeight']['logicalBytesSHA256']='0'*64
            with self.assertRaisesRegex(ValueError,'fused source bytes'):verify_real_weight_bytes(r,d,TEXT)
    def test_native_metrics_are_recomputed_and_missing_component_rejected(self):
        r=fixture('bfloat16');oracle=projection_oracle(r,TEXT);native=[]
        for rank in oracle['ranks']:
            for c in rank['components']:
                m=c['aggregate'];native.append(dict(rank=rank['rank'],component=c['name'],comparedValues=m['comparedValues'],
                    exactValues=m['exact'],differingValues=m['differingValues'],maximumAbsoluteError=m['maximumAbsoluteError'],
                    rootMeanSquareError=m['rootMeanSquareError'],relativeRMSError=m['relativeRMSError'],bfloat16Steps=c['bfloat16Steps']))
        native[0]['maximumAbsoluteError']=0 # Swift may encode a zero Double as JSON 0.
        verify_native_differences(native,oracle)
        native[0]['bfloat16Steps']=dict(native[0]['bfloat16Steps'],maximumAbsoluteSteps=1)
        with self.assertRaisesRegex(ValueError,'BF16 steps'):verify_native_differences(native,oracle)
        with self.assertRaisesRegex(ValueError,'Missing native'):verify_native_differences(native[:-1],oracle)
    def test_wrong_quantization_or_stored_axis_rejected(self):
        r=fixture();r['sourceProjections'][0]['bits']=8;r['sourceProjectionsSHA256']=digest(canonical(r['sourceProjections']))
        with self.assertRaisesRegex(ValueError,'projection metadata'):projection_oracle(r,TEXT)
        r=fixture();r['ranks'][1]['fusedWeight']['shape']=[65,16]
        with self.assertRaisesRegex(ValueError,'parameter identity'):projection_oracle(r,TEXT)
    def test_diagnostic_json_preserves_signed_zero_and_rejects_duplicate_identity(self):
        spec=importlib.util.spec_from_file_location('gdn_driver',Path(__file__).with_name('validate-qwen-gdn-input.py'))
        driver=importlib.util.module_from_spec(spec);spec.loader.exec_module(driver)
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'stdout.txt';p.write_text('{"values":[-0,0]}\n')
            values=driver.read_diagnostic(p)['values']
            self.assertEqual(logical_bytes(values,'bfloat16'),b'\x00\x80\x00\x00')
            p.write_text('{"schemaVersion":1,"schemaVersion":2}\n')
            with self.assertRaisesRegex(ValueError,'Duplicate'):driver.read_diagnostic(p)
        self.assertLessEqual(driver.DIAGNOSTIC_KNOWN_EXTRA,driver.DIAGNOSTIC_RESERVE)
    def test_bf16_steps_cross_signed_zero_and_sign(self):
        a=bf16_steps([-0.0,-1.0],[0.0,1.0]);self.assertEqual(a['maximumAbsoluteSteps'],32512)
        self.assertEqual(a['greaterThanOneStepDifferences'],1)


if __name__=='__main__':unittest.main()
