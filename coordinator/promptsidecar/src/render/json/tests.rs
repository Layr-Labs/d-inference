use super::*;
use minijinja::Environment;
use serde_json::{Value, json};

// Captured from the actual Swift-Jinja 2.3.6 source by the provider validation
// lane; output SHA256 ef05fde3be627726b7e117b2b4255052b092cfbf16fbece116317c6820e61276.
// This is a byte oracle, not a second implementation of this Rust formatter.
#[test]
fn matches_swift_236_json_goldens() {
    let rows: Value = serde_json::from_str(include_str!("swift_236_goldens.json")).unwrap();
    let mut environment = Environment::new();
    environment.add_filter("tojson", tojson);
    for row in rows.as_array().unwrap() {
        let id = row["id"].as_str().unwrap();
        let input = match id.split('_').next().unwrap() {
            "nested" => json!({"z":[{"y":2,"a":1}],"a":{"B":3,"a":4}}),
            "unicode" if id.starts_with("unicode_order_") => json!({"\u{e000}":1,"\u{10000}":2}),
            "unicode" => {
                json!({"z":"é 🐱 日本語 / slash < > & ' \" \\ \u{2028}\u{2029}","é":"line\nreturn\rtab\tback\u{8}form\u{c}\u{1}"})
            }
            "numbers" => json!([
                1.0,
                -0.0,
                0.000001,
                0.0000001,
                1e20,
                1e21,
                1.25,
                1e20,
                1e15,
                1e16,
                1.2345678901234567,
                9007199254740993_i64,
                i64::MAX,
                i64::MIN
            ]),
            "transitions" => json!([
                1e-3,
                1e-4,
                1e-5,
                1e14,
                1e15,
                1e16,
                1.2345e-4,
                1.2345e-5,
                1.23456789e15,
                1.23456789e16,
                0.0,
                -0.0,
                f64::from_bits(1),
                f64::MAX
            ]),
            "keysort" => json!({"Z":1,"a":2,"_":3,"é":4,"e":5,"A":6,"中":7}),
            "empty" => json!({"object":{},"array":[]}),
            "primitives" => json!([true, false, null, ""]),
            _ => panic!("unexpected Swift golden {id}"),
        };
        let actual = environment
            .render_str(row["template"].as_str().unwrap(), json!({"value":input}))
            .unwrap();
        assert_eq!(actual, row["output"].as_str().unwrap(), "Swift golden {id}");
    }
    assert_eq!(rows.as_array().unwrap().len(), 104);
}

#[test]
fn json_sorting_does_not_change_object_iteration_or_loop_neighbors() {
    let mut environment = Environment::new();
    environment.add_filter("tojson", tojson);
    let context = json!({"value":{"z":1,"a":2},"messages":[{"role":"assistant","content":"calling"},{"role":"tool","content":"one"},{"role":"tool","content":"two"}]});
    let template = "{{ value|tojson }}|{% for key in value %}{{ key }}{% endfor %}|{% for m in messages %}{% if m.role == 'tool' %}{% if loop.previtem and loop.previtem.role != 'tool' %}USER|{% endif %}[{{ m.content }}]{% if not loop.last and loop.nextitem.role != 'tool' %}|END{% elif loop.last %}|END{% endif %}{% endif %}{% endfor %}";
    assert_eq!(
        environment.render_str(template, context).unwrap(),
        "{\"a\":2,\"z\":1}|za|USER|[one][two]|END"
    );
}

#[test]
fn serialization_refuses_excess_output_without_an_unbounded_result_buffer() {
    let mut output = BoundedWriter::new(32);
    assert!(
        write_value(
            &JinjaValue::from("🐱".repeat(8)),
            &mut output,
            false,
            true,
            0
        )
        .is_err()
    );
    assert!(output.exceeded);
    assert!(output.bytes.len() <= 32);
}

#[test]
fn invalid_filter_options_fail_instead_of_silently_changing_output() {
    let mut environment = Environment::new();
    environment.add_filter("tojson", tojson);
    for template in [
        "{{ 1|tojson(2,indent=4) }}",
        "{{ 1|tojson(sort_keys=false) }}",
        "{{ 1|tojson(2,indent=none) }}",
    ] {
        assert!(environment.render_str(template, ()).is_err(), "{template}");
    }
    assert_eq!(
        environment.render_str("{{ missing|tojson }}", ()).unwrap(),
        "null"
    );
}

// Same exact upstream source as the main oracle, with 512 deterministic finite
// bit patterns plus nested nonfinite, key-order and positional-argument cases. This checks
// shortest decimal digits as well as the exponent-format transition policy.
#[test]
fn matches_swift_236_number_and_argument_edges() {
    let rows: Value = serde_json::from_str(include_str!("swift_236_edges.json")).unwrap();
    let mut environment = Environment::new();
    environment.add_filter("tojson", tojson);
    for row in rows.as_array().unwrap() {
        let id = row["id"].as_str().unwrap();
        let input = if id.starts_with("numeric_keys_") {
            JinjaValue::from_serialize(json!({"2":2,"10":10,"01":1,"1":3}))
        } else if id.starts_with("unicode_keys_") {
            JinjaValue::from_serialize(json!({"e":1,"e\u{300}":2,"e\u{302}":3,"é":4,"êx":5}))
        } else if id.starts_with("canonical_collision_last_assignment_") {
            // The oracle constructs a Swift dictionary: equivalent keys have
            // ALREADY collapsed before tojson. This is not a claim about raw
            // JSON decoder collision order or normalizing MiniJinja maps.
            JinjaValue::from_serialize(json!({"é":2}))
        } else if let Some(bits) = row["bits"].as_str() {
            JinjaValue::from(f64::from_bits(u64::from_str_radix(bits, 16).unwrap()))
        } else if id.starts_with("infinity_array_") {
            JinjaValue::from(vec![JinjaValue::from(f64::INFINITY), JinjaValue::from(1)])
        } else if id.starts_with("nan_object_") {
            JinjaValue::from_iter([(
                "nested",
                JinjaValue::from_iter([
                    ("a", JinjaValue::from(1)),
                    ("b", JinjaValue::from(f64::NAN)),
                ]),
            )])
        } else if id.starts_with("nan_") {
            JinjaValue::from(f64::NAN)
        } else if id.starts_with("minus_infinity_array_") {
            JinjaValue::from(vec![
                JinjaValue::from(vec![JinjaValue::from(f64::NEG_INFINITY)]),
                JinjaValue::from(1),
            ])
        } else if id.starts_with("minus_infinity_") {
            JinjaValue::from(f64::NEG_INFINITY)
        } else if id.starts_with("positional_unicode_") {
            JinjaValue::from_serialize(json!({"猫":"雪 🐱 /"}))
        } else {
            panic!("unexpected edge {id}")
        };
        let actual = environment
            .render_str(
                row["template"].as_str().unwrap(),
                minijinja::context! {value => input},
            )
            .unwrap();
        assert_eq!(actual, row["output"].as_str().unwrap(), "Swift edge {id}");
    }
    assert_eq!(rows.as_array().unwrap().len(), 530);
}

#[test]
fn sort_scratch_and_nested_output_share_the_bound() {
    let mut output = BoundedWriter::new(16);
    let object = JinjaValue::from_serialize(json!({"a":1,"b":2}));
    assert!(write_value(&object, &mut output, false, true, 0).is_err());
    assert!(output.exceeded);
    assert!(output.bytes.is_empty());
    let mut output = BoundedWriter::new(256);
    assert!(write_value(&object, &mut output, false, true, 0).is_ok());
    assert_eq!(output.limit, 256, "sort reservation did not retire");
}

#[test]
fn bounded_writer_caps_allocated_capacity_and_large_indent() {
    let mut output = BoundedWriter::new(100);
    // An initial odd capacity followed by growth must not round up past100.
    output.write_all(&[b'a'; 31]).unwrap();
    output.write_all(&[b'b'; 62]).unwrap();
    assert!(output.bytes.capacity() <= 100);
    assert_eq!(output.bytes.len(), 93);
    let mut environment = Environment::new();
    environment.add_filter("tojson", tojson);
    assert_eq!(
        environment
            .render_str("{{ [1]|tojson(indent=9223372036854775807) }}", ())
            .unwrap(),
        "[\n  1\n]"
    );
}

#[test]
fn explicit_null_option_does_not_become_an_omitted_default() {
    let mut environment = Environment::new();
    environment.add_filter("tojson", tojson);
    for template in [
        "{{ 'é'|tojson(ensure_ascii=none) }}",
        "{{ 'é'|tojson(none,none) }}",
    ] {
        assert_eq!(environment.render_str(template, ()).unwrap(), "\"é\"");
    }
}

// The serializer oracle creates typed Doubles. Raw JSON must also decode the
// same decimal into the same bits before serialization; serde_json's default
// fast parser differed on 136 of these 512 real Swift outputs.
#[test]
fn exact_decimal_parser_matches_all_swift_finite_bit_patterns() {
    let rows: Value = serde_json::from_str(include_str!("swift_236_edges.json")).unwrap();
    let mut environment = Environment::new();
    environment.add_filter("tojson", tojson);
    let mut count = 0;
    for row in rows.as_array().unwrap() {
        let Some(bits) = row["bits"].as_str() else {
            continue;
        };
        let decimal = row["output"].as_str().unwrap();
        let value: Value = serde_json::from_str(decimal).unwrap();
        let expected = u64::from_str_radix(bits, 16).unwrap();
        assert_eq!(value.as_f64().unwrap().to_bits(), expected, "{}", row["id"]);
        assert_eq!(
            environment
                .render_str("{{ value|tojson }}", json!({"value":value}))
                .unwrap(),
            decimal,
            "{}",
            row["id"]
        );
        count += 1;
    }
    assert_eq!(count, 512);
}
