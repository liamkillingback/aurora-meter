# 03a schema diff: `aurora_meter_events` before and after

Measured by `tmp/v1/03a/rehearse.exs` against a disposable database
(`aurora_v1_1_2284530`, dropped afterwards) populated with 12002 rows
in the 0.4.0 shape, then upgraded core 6 -> 7 -> backfill -> 8.

## Before (core schema 6)

```
                                                     Table "public.aurora_meter_events"
   Column    |            Type             | Collation | Nullable |      Default      | Storage  | Compression | Stats target | Description 
-------------+-----------------------------+-----------+----------+-------------------+----------+-------------+--------------+-------------
 id          | uuid                        |           | not null | gen_random_uuid() | plain    |             |              | 
 tenant_key  | character varying(255)      |           | not null |                   | extended |             |              | 
 feature     | character varying(255)      |           | not null |                   | extended |             |              | 
 quantity    | integer                     |           | not null | 1                 | plain    |             |              | 
 metadata    | jsonb                       |           | not null | '{}'::jsonb       | extended |             |              | 
 inserted_at | timestamp without time zone |           | not null |                   | plain    |             |              | 
Indexes:
    "aurora_meter_events_pkey" PRIMARY KEY, btree (id)
    "aurora_meter_events_tenant_key_feature_inserted_at_index" btree (tenant_key, feature, inserted_at)
Access method: heap


```

## After (core schema 8)

```
                                                               Table "public.aurora_meter_events"
      Column       |              Type              | Collation | Nullable |           Default            | Storage  | Compression | Stats target | Description 
-------------------+--------------------------------+-----------+----------+------------------------------+----------+-------------+--------------+-------------
 id                | uuid                           |           | not null | gen_random_uuid()            | plain    |             |              | 
 tenant_key        | character varying(255)         |           | not null |                              | extended |             |              | 
 feature           | character varying(255)         |           | not null |                              | extended |             |              | 
 quantity          | bigint                         |           | not null | 1                            | plain    |             |              | 
 metadata          | jsonb                          |           | not null | '{}'::jsonb                  | extended |             |              | 
 inserted_at       | timestamp without time zone    |           | not null |                              | plain    |             |              | 
 seq               | bigint                         |           | not null | generated always as identity | plain    |             |              | 
 event_id          | text                           |           | not null |                              | extended |             |              | 
 payload_hash      | bytea                          |           | not null |                              | extended |             |              | 
 occurred_at       | timestamp without time zone    |           | not null |                              | plain    |             |              | 
 period_start      | timestamp(0) without time zone |           |          |                              | plain    |             |              | 
 period_source     | text                           |           |          |                              | extended |             |              | 
 kind              | text                           |           | not null | 'usage'::text                | extended |             |              | 
 original_event_id | text                           |           |          |                              | extended |             |              | 
 dimensions        | jsonb                          |           | not null | '{}'::jsonb                  | extended |             |              | 
 plan_id           | text                           |           |          |                              | extended |             |              | 
 plan_version      | text                           |           |          |                              | extended |             |              | 
 attribution       | text                           |           |          |                              | extended |             |              | 
Indexes:
    "aurora_meter_events_pkey" PRIMARY KEY, btree (id)
    "aurora_meter_events_corrections_index" btree (tenant_key, original_event_id) WHERE kind = 'correction'::text
    "aurora_meter_events_seq_index" UNIQUE, btree (seq)
    "aurora_meter_events_tenant_event_id_index" UNIQUE, btree (tenant_key, event_id)
    "aurora_meter_events_tenant_key_feature_inserted_at_index" btree (tenant_key, feature, inserted_at)
Check constraints:
    "aurora_meter_events_correction_pairing_check" CHECK ((kind = 'correction'::text) = (original_event_id IS NOT NULL))
    "aurora_meter_events_dimensions_object_check" CHECK (jsonb_typeof(dimensions) = 'object'::text)
    "aurora_meter_events_event_id_length_check" CHECK (octet_length(event_id) <= 128)
    "aurora_meter_events_kind_check" CHECK (kind = ANY (ARRAY['usage'::text, 'correction'::text]))
    "aurora_meter_events_metadata_size_check" CHECK (octet_length(metadata::text) <= 16384) NOT VALID
    "aurora_meter_events_quantity_check" CHECK (quantity > 0) NOT VALID
Access method: heap


```

## `aurora_meter_event_totals` (new in version 7)

```
                                                    Table "public.aurora_meter_event_totals"
    Column    |              Type              | Collation | Nullable |      Default      | Storage  | Compression | Stats target | Description 
--------------+--------------------------------+-----------+----------+-------------------+----------+-------------+--------------+-------------
 id           | uuid                           |           | not null | gen_random_uuid() | plain    |             |              | 
 tenant_key   | character varying(255)         |           | not null |                   | extended |             |              | 
 feature      | character varying(255)         |           | not null |                   | extended |             |              | 
 period_start | timestamp(0) without time zone |           | not null |                   | plain    |             |              | 
 generation   | integer                        |           | not null | 0                 | plain    |             |              | 
 quantity     | bigint                         |           | not null | 0                 | plain    |             |              | 
 events       | bigint                         |           | not null | 0                 | plain    |             |              | 
 inserted_at  | timestamp without time zone    |           | not null |                   | plain    |             |              | 
 updated_at   | timestamp without time zone    |           | not null |                   | plain    |             |              | 
Indexes:
    "aurora_meter_event_totals_pkey" PRIMARY KEY, btree (id)
    "aurora_meter_event_totals_generation_index" btree (generation)
    "aurora_meter_event_totals_key_index" UNIQUE, btree (tenant_key, feature, period_start, generation)
Check constraints:
    "aurora_meter_event_totals_events_check" CHECK (events >= 0)
    "aurora_meter_event_totals_quantity_check" CHECK (quantity >= 0)
Access method: heap


```

## `aurora_meter_checkpoints` (new in version 7)

```
                                                               Table "public.aurora_meter_checkpoints"
   Column   |            Type             | Collation | Nullable |                   Default                    | Storage  | Compression | Stats target | Description 
------------+-----------------------------+-----------+----------+----------------------------------------------+----------+-------------+--------------+-------------
 name       | text                        |           | not null |                                              | extended |             |              | 
 cursor     | jsonb                       |           | not null | '{}'::jsonb                                  | extended |             |              | 
 counts     | jsonb                       |           | not null | '{}'::jsonb                                  | extended |             |              | 
 state      | text                        |           | not null | 'idle'::text                                 | extended |             |              | 
 updated_at | timestamp without time zone |           | not null | (clock_timestamp() AT TIME ZONE 'UTC'::text) | plain    |             |              | 
Indexes:
    "aurora_meter_checkpoints_pkey" PRIMARY KEY, btree (name)
Access method: heap


```

## `pg_constraint.convalidated`

This run used `validate_checks: false`, because the population deliberately
holds one row with a non-positive quantity and one with oversized metadata,
which is what a real 0.4.x database can hold. Six constraints, two unproven:

```
                   conname                    | convalidated 
----------------------------------------------+--------------
 aurora_meter_events_correction_pairing_check | t
 aurora_meter_events_dimensions_object_check  | t
 aurora_meter_events_event_id_length_check    | t
 aurora_meter_events_kind_check               | t
 aurora_meter_events_metadata_size_check      | f
 aurora_meter_events_quantity_check           | f
(6 rows)


```
