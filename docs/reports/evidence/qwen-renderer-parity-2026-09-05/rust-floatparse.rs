fn main() {
 let rows: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap()).unwrap();
 let mut count=0; let mut mismatches=0;
 for row in rows.as_array().unwrap() { if let Some(bits)=row["bits"].as_str() {
  let expected=u64::from_str_radix(bits,16).unwrap(); let decimal=row["output"].as_str().unwrap();
  let actual: f64=serde_json::from_str(decimal).unwrap(); count+=1;
  if actual.to_bits()!=expected {mismatches+=1; if mismatches<=8 {println!("{} {} {:x} {:x}",row["id"],decimal,expected,actual.to_bits());}}
 }} println!("samples={count} mismatches={mismatches}");
}