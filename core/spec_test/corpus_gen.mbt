// SPDX-License-Identifier: Apache-2.0
// AUTO-GENERATED from core/spec/testdata/spec_corpus.json — do not edit.
// Regenerate: python3 tools/gen_spec_corpus.py

///|
/// A valid spec document (must parse).
struct ValidCase {
  name : String
  json : String
} derive(Debug, Eq)

///|
/// An invalid spec document: must fail and report every listed code.
struct InvalidCase {
  name : String
  json : String
  expect_codes : Array[String]
} derive(Debug, Eq)

///|
let valid_cases : Array[ValidCase] = [
  ValidCase::{
    name: "minimal-file-to-stdout",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"file-to-stdout\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"events.txt\"},\"transforms\":[],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}}}",
  },
  ValidCase::{
    name: "with-expr-transform",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x-1\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"/tmp/in.log\"},\"transforms\":[{\"type\":\"expr\",\"expr\":\".value | trim()\"}],\"topic\":{\"name\":\"t_1.log\"},\"sink\":{\"type\":\"stdout\"}}}",
  },
  ValidCase::{
    name: "http-source",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"connector-demo\"},\"spec\":{\"source\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:18080/data\"},\"transforms\":[],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}}}",
  },
  ValidCase::{
    name: "stdin-source",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"connector-demo\"},\"spec\":{\"source\":{\"type\":\"stdin\"},\"transforms\":[],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"stdout\"}}}",
  },
  ValidCase::{
    name: "http-sink",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"connector-demo\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"in.txt\"},\"transforms\":[],\"topic\":{\"name\":\"events\"},\"sink\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:18080/sink\"}}}",
  },
  ValidCase::{
    name: "wasm-transform",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"wasm-op\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"in.txt\"},\"transforms\":[{\"type\":\"wasm\",\"module\":\"ops/upper.wasm\"}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
  },
  ValidCase::{
    name: "wasm-transform-with-config",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"wasm-op-cfg\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"in.txt\"},\"transforms\":[{\"type\":\"wasm\",\"module\":\"ops/upper.wasm\",\"config\":{\"mode\":\"identity\",\"level\":3}}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
  },
]

///|
let invalid_cases : Array[InvalidCase] = [
  InvalidCase::{
    name: "wrong-api-version",
    json: "{\"apiVersion\":\"v1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["bad-api-version"],
  },
  InvalidCase::{
    name: "wrong-kind",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Deployment\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["bad-kind"],
  },
  InvalidCase::{
    name: "uppercase-metadata-name",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"Bad\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["bad-name"],
  },
  InvalidCase::{
    name: "unknown-source-type",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"amqp\",\"path\":\"p\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["bad-value"],
  },
  InvalidCase::{
    name: "empty-source-path",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["bad-value"],
  },
  InvalidCase::{
    name: "unknown-sink-type",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"kinesis\"}}}",
    expect_codes: ["bad-value"],
  },
  InvalidCase::{
    name: "path-traversal-topic",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"topic\":{\"name\":\"../escape\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["bad-name"],
  },
  InvalidCase::{
    name: "unknown-fields-everywhere",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\",\"a\":1},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\",\"b\":1},\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"},\"c\":1},\"d\":1}",
    expect_codes: [
      "unknown-field", "unknown-field", "unknown-field", "unknown-field",
    ],
  },
  InvalidCase::{
    name: "missing-spec",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"}}",
    expect_codes: ["missing-field"],
  },
  InvalidCase::{
    name: "transform-missing-expr",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"transforms\":[{\"type\":\"expr\"}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["missing-field"],
  },
  InvalidCase::{
    name: "transform-unknown-type",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"transforms\":[{\"type\":\"magic\"}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["bad-value"],
  },
  InvalidCase::{
    name: "http-source-missing-url",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"http\"},\"transforms\":[],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["missing-field"],
  },
  InvalidCase::{
    name: "http-source-bad-scheme",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"http\",\"url\":\"https://x/y\"},\"transforms\":[],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["bad-value"],
  },
  InvalidCase::{
    name: "http-sink-missing-url",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"transforms\":[],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"http\"}}}",
    expect_codes: ["missing-field"],
  },
  InvalidCase::{
    name: "wasm-transform-missing-module",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"transforms\":[{\"type\":\"wasm\"}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["missing-field"],
  },
  InvalidCase::{
    name: "wasm-transform-empty-module",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"p\"},\"transforms\":[{\"type\":\"wasm\",\"module\":\"\"}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["bad-value"],
  },
  InvalidCase::{
    name: "wasm-transform-config-not-object",
    json: "{\"apiVersion\":\"moonflux.io/v1alpha1\",\"kind\":\"Pipeline\",\"metadata\":{\"name\":\"x\"},\"spec\":{\"source\":{\"type\":\"file\",\"path\":\"in.txt\"},\"transforms\":[{\"type\":\"wasm\",\"module\":\"ops/upper.wasm\",\"config\":\"nope\"}],\"topic\":{\"name\":\"t\"},\"sink\":{\"type\":\"stdout\"}}}",
    expect_codes: ["bad-type"],
  },
]
