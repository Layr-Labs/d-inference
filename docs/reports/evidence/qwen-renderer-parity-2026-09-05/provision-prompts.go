package main

import (
 "crypto/sha256"
 "encoding/hex"
 "encoding/json"
 "fmt"
 "os"
 "path/filepath"
 "sort"
 "strings"
 pc "github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func check(err error) { if err != nil { panic(err) } }
func main() {
 if len(os.Args)==2 && os.Args[1]=="contract-vector" {
  p:="fixtures/prompt-contract/v1/contract_vectors.json"
  b,e:=os.ReadFile(p);check(e)
  var corpus map[string]json.RawMessage;check(json.Unmarshal(b,&corpus))
  var vectors []map[string]json.RawMessage;check(json.Unmarshal(corpus["vectors"],&vectors))
  for _,v:=range vectors {
   var artifacts []pc.Artifact;check(json.Unmarshal(v["artifacts"],&artifacts))
   id,e:=pc.ContractID(artifacts,pc.CurrentVersions());check(e)
   v["expected_prompt_contract_id"],e=json.Marshal(id);check(e)
  }
  corpus["vectors"],e=json.Marshal(vectors);check(e)
  b,e=json.MarshalIndent(corpus,"","  ");check(e);check(os.WriteFile(p,append(b,'\n'),0644));return
 }
 rawRoot,manifestRoot,outRoot:=os.Args[1],os.Args[2],os.Args[3]
 entries,e:=os.ReadDir(manifestRoot);check(e)
 for _,entry:=range entries {
  if !strings.HasSuffix(entry.Name(),".json") {continue}
  b,e:=os.ReadFile(filepath.Join(manifestRoot,entry.Name()));check(e)
  var m struct { ModelID string `json:"model_id"`; ModelType string `json:"model_type"`; Aggregate string `json:"aggregate_sha256"`; Files []pc.Artifact `json:"files"` }
  check(json.Unmarshal(b,&m))
  artifacts:=[]pc.Artifact{}
  for _,f:=range m.Files {if f.Role=="config"||f.Role=="tokenizer"||f.Role=="template" {artifacts=append(artifacts,f)}}
  id,e:=pc.ContractID(artifacts,pc.CurrentVersions());check(e)
  root:=filepath.Join(outRoot,id);check(os.MkdirAll(root,0700))
  modelDir:=m.ModelID
  if m.ModelID=="gemma-4-26b-8bit" {modelDir="gemma-4-26b"}
  for _,f:=range artifacts {
   if filepath.Base(f.Path)!=f.Path {panic("unexpected nested artifact")}
   b,e:=os.ReadFile(filepath.Join(rawRoot,modelDir,f.Path));check(e)
   digest:=sha256.Sum256(b)
   if int64(len(b))!=f.SizeBytes||hex.EncodeToString(digest[:])!=f.SHA256 {panic("integrity: "+m.ModelID+"/"+f.Path)}
   check(os.WriteFile(filepath.Join(root,f.Path),b,0600))
  }
  sort.Slice(artifacts,func(i,j int)bool{return artifacts[i].Path<artifacts[j].Path})
  meta:=pc.Metadata{SchemaVersion:1,PromptContractID:id,ModelID:m.ModelID,ModelType:m.ModelType,ModelAggregateSHA256:m.Aggregate,Artifacts:artifacts,Versions:pc.CurrentVersions()}
  b,e=json.MarshalIndent(meta,"","  ");check(e);check(os.WriteFile(filepath.Join(root,pc.MetadataFile),b,0600))
  fmt.Println(m.ModelID,id,len(artifacts))
 }
}
