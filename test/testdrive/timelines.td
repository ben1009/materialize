# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

# Test various joins and how they interact with timeline checks.

$ set schema={
    "type": "record",
    "name": "envelope",
    "fields": [
      {
        "name": "before",
        "type": [
          {
            "name": "row",
            "type": "record",
            "fields": [
              {"name": "a", "type": "long"},
              {"name": "b", "type": "long"}
            ]
          },
          "null"
        ]
      },
      { "name": "after", "type": ["row", "null"] }
    ]
  }

$ kafka-create-topic topic=input-consistency
$ kafka-create-topic topic=input-system

> CREATE MATERIALIZED SOURCE source_byo
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-${testdrive.seed}'
    WITH (consistency_topic = 'testdrive-input-consistency-${testdrive.seed}')
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE DEBEZIUM

> CREATE MATERIALIZED SOURCE source_byo_user
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-${testdrive.seed}'
    WITH (consistency_topic = 'testdrive-input-consistency-${testdrive.seed}', timeline = 'user')
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE DEBEZIUM

> CREATE MATERIALIZED SOURCE source_byo_user2
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-${testdrive.seed}'
    WITH (consistency_topic = 'testdrive-input-consistency-${testdrive.seed}', timeline = 'user2')
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE DEBEZIUM

> CREATE MATERIALIZED SOURCE source_system
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-system-${testdrive.seed}'
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE DEBEZIUM

> CREATE MATERIALIZED SOURCE source_system_user
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-system-${testdrive.seed}'
    WITH (timeline = 'user')
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE DEBEZIUM

$ set schema=[
  {
    "type": "array",
    "items": {
      "type": "record",
      "name": "update",
      "namespace": "com.materialize.cdc",
      "fields": [
        {
          "name": "data",
          "type": {
            "type": "record",
            "name": "data",
            "fields": [
              {
                "name": "id",
                "type": "long"
              },
              {
                "name": "price",
                "type": [
                  "null",
                  "int"
                ]
              }
            ]
          }
        },
        {
          "name": "time",
          "type": "long"
        },
        {
          "name": "diff",
          "type": "long"
        }
      ]
    }
  },
  {
    "type": "record",
    "name": "progress",
    "namespace": "com.materialize.cdc",
    "fields": [
      {
        "name": "lower",
        "type": {
          "type": "array",
          "items": "long"
        }
      },
      {
        "name": "upper",
        "type": {
          "type": "array",
          "items": "long"
        }
      },
      {
        "name": "counts",
        "type": {
          "type": "array",
          "items": {
            "type": "record",
            "name": "counts",
            "fields": [
              {
                "name": "time",
                "type": "long"
              },
              {
                "name": "count",
                "type": "long"
              }
            ]
          }
        }
      }
    ]
  }
  ]

$ kafka-create-topic topic=input-cdcv2

$ kafka-ingest format=avro topic=input-cdcv2 schema=${schema} timestamp=1
{"array":[{"data":{"id":5,"price":{"int":10}},"time":5,"diff":1}]}
{"array":[{"data":{"id":5,"price":{"int":12}},"time":4,"diff":1}]}
{"array":[{"data":{"id":5,"price":{"int":12}},"time":5,"diff":-1}]}

> CREATE MATERIALIZED SOURCE source_cdcv2
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-cdcv2-${testdrive.seed}'
  FORMAT AVRO USING SCHEMA '${schema}'
  ENVELOPE MATERIALIZE

! CREATE MATERIALIZED SOURCE source_cdcv2_system
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-cdcv2-${testdrive.seed}'
    WITH (epoch_ms_timeline=false)
  FORMAT AVRO USING SCHEMA '${schema}'
  ENVELOPE MATERIALIZE
unsupported epoch_ms_timeline value

# Can't specify epoch_ms_timeline and timeline.
! CREATE MATERIALIZED SOURCE source_cdcv2_system
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-cdcv2-${testdrive.seed}'
    WITH (epoch_ms_timeline=false, timeline='user')
  FORMAT AVRO USING SCHEMA '${schema}'
  ENVELOPE MATERIALIZE
unexpected parameters for CREATE SOURCE: epoch_ms_timeline

> CREATE MATERIALIZED SOURCE source_cdcv2_system
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-cdcv2-${testdrive.seed}'
    WITH (epoch_ms_timeline=true)
  FORMAT AVRO USING SCHEMA '${schema}'
  ENVELOPE MATERIALIZE

> CREATE MATERIALIZED SOURCE source_cdcv2_user
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-cdcv2-${testdrive.seed}'
    WITH (timeline='user')
  FORMAT AVRO USING SCHEMA '${schema}'
  ENVELOPE MATERIALIZE

> CREATE TABLE input_table (a bigint);

> CREATE VIEW input_values_view AS VALUES (1), (2), (3);

> CREATE MATERIALIZED VIEW input_values_mview AS VALUES (1), (2), (3);

! CREATE VIEW must_fail AS SELECT * FROM source_byo, source_system;
Dataflow cannot use multiple timelines

! CREATE MATERIALIZED VIEW must_fail AS SELECT * FROM source_system, source_byo;
Dataflow cannot use multiple timelines

! CREATE MATERIALIZED VIEW must_fail AS SELECT * FROM source_system, source_byo;
Dataflow cannot use multiple timelines

! CREATE MATERIALIZED VIEW must_fail AS SELECT * FROM source_system, source_cdcv2;
Dataflow cannot use multiple timelines

! CREATE MATERIALIZED VIEW must_fail AS SELECT * FROM source_byo, source_cdcv2;
Dataflow cannot use multiple timelines

! CREATE MATERIALIZED VIEW must_fail AS SELECT (SELECT a FROM source_system LIMIT 1) FROM source_byo;
Dataflow cannot use multiple timelines

# Verify that user timelines don't allow things to be joinable with their non-user versions.
! CREATE MATERIALIZED VIEW must_fail AS SELECT * FROM source_system, source_system_user;
Dataflow cannot use multiple timelines
! CREATE MATERIALIZED VIEW must_fail AS SELECT * FROM source_byo, source_byo_user;
Dataflow cannot use multiple timelines

# Can join static view with anything.
> CREATE VIEW values_table_view AS SELECT * FROM input_values_view, input_table;
> CREATE VIEW values_values_view AS SELECT * FROM input_values_view, input_values_mview LIMIT 0;
> CREATE VIEW values_system_view AS SELECT * FROM input_values_view, source_system;
> CREATE VIEW values_system_user_view AS SELECT * FROM input_values_view, source_system_user;
> CREATE VIEW values_cdcv2_view AS SELECT * FROM input_values_view, source_cdcv2;
> CREATE VIEW values_byo_view AS SELECT * FROM input_values_view, source_byo;
> CREATE VIEW values_byo_user_view AS SELECT * FROM input_values_view, source_byo_user;
> CREATE VIEW values_mz_catalog_view AS SELECT * FROM input_values_view, mz_catalog_names, mz_views, mz_source_info;

# System sources, tables, and logs should be joinable with eachother.
> CREATE VIEW various_system AS SELECT * FROM mz_catalog_names, mz_views, mz_source_info;

# System things should be joinable only with system sources.
! CREATE VIEW must_fail AS SELECT * FROM mz_catalog_names, mz_views, mz_source_info, source_byo;
Dataflow cannot use multiple timelines
! CREATE VIEW must_fail AS SELECT * FROM mz_catalog_names, mz_views, mz_source_info, source_cdcv2;
Dataflow cannot use multiple timelines
> CREATE VIEW various_system_no_byo AS SELECT * FROM mz_catalog_names, mz_views, mz_source_info, source_system;
> CREATE VIEW various_system_table AS SELECT * FROM mz_catalog_names, mz_views, mz_source_info, input_table;

# EXPLAIN should complain too.
! EXPLAIN SELECT * FROM source_system, source_byo;
Dataflow cannot use multiple timelines

# Can join user-specified timelines.
> CREATE MATERIALIZED VIEW source_system_byo_user AS SELECT * FROM source_system_user, source_byo_user, source_cdcv2_user;

# Unless they are from different user timelines.
! CREATE MATERIALIZED VIEW must_fail AS SELECT * FROM source_byo_user, source_byo_user2;
Dataflow cannot use multiple timelines

# CDCv2 can only be joined with system time stuff if specified
> CREATE MATERIALIZED VIEW source_cdcv2_table_system AS SELECT * FROM source_cdcv2_system, input_table;
! CREATE MATERIALIZED VIEW must_fail AS SELECT * FROM source_cdcv2, input_table;
Dataflow cannot use multiple timelines

# Verify that timedomains don't cross timelines. In the case that
# source_byo is grouped in the same timedomain as epoch ms sources,
# the SELECT will hang forever. We expect the error here since we have
# not written any rows so its upper is still 0, which determine_timestamp
# complains about.
> BEGIN;
! SELECT * FROM source_byo;
At least one input has no complete timestamps yet
> ROLLBACK;

# Verify that if the transaction starts on some timeline (epoch ms here),
# things outside that are not there due to timedomain reasons.
> BEGIN;
> SELECT * FROM input_table;
! SELECT * FROM source_byo;
transactions can only reference nearby relations
> ROLLBACK;
