-- Test passing off CALL to mx workers

-- Create worker-local tables to test procedure calls were routed

set citus.shard_replication_factor to 2;
set citus.replication_model to 'statement';

-- This table requires specific settings, create before getting into things
create table mx_call_dist_table_replica(id int, val int);
select create_distributed_table('mx_call_dist_table_replica', 'id');
insert into mx_call_dist_table_replica values (9,1),(8,2),(7,3),(6,4),(5,5);

set citus.shard_replication_factor to 1;
set citus.replication_model to 'streaming';

create schema multi_mx_call;
set search_path to multi_mx_call, public;

--
-- Utility UDFs
--

-- 1. Marks the given procedure as colocated with the given table.
-- 2. Marks the argument index with which we route the procedure.
CREATE PROCEDURE colocate_proc_with_table(procname text, tablerelid regclass, argument_index int)
LANGUAGE plpgsql AS $$
BEGIN
    update citus.pg_dist_object
    set distribution_argument_index = argument_index, colocationid = pg_dist_partition.colocationid
    from pg_proc, pg_dist_partition
    where proname = procname and oid = objid and pg_dist_partition.logicalrelid = tablerelid;
END;$$;


--
-- Create tables and procedures we want to use in tests
--
create table mx_call_dist_table_1(id int, val int);
select create_distributed_table('mx_call_dist_table_1', 'id');
insert into mx_call_dist_table_1 values (3,1),(4,5),(9,2),(6,5),(3,5);

create table mx_call_dist_table_2(id int, val int);
select create_distributed_table('mx_call_dist_table_2', 'id');
insert into mx_call_dist_table_2 values (1,1),(1,2),(2,2),(3,3),(3,4);

create table mx_call_dist_table_ref(id int, val int);
select create_reference_table('mx_call_dist_table_ref');
insert into mx_call_dist_table_ref values (2,7),(1,8),(2,8),(1,8),(2,8);

create type mx_call_enum as enum ('A', 'S', 'D', 'F');
create table mx_call_dist_table_enum(id int, key mx_call_enum);
select create_distributed_table('mx_call_dist_table_enum', 'key');
insert into mx_call_dist_table_enum values (1,'S'),(2,'A'),(3,'D'),(4,'F');


CREATE PROCEDURE mx_call_proc(x int, INOUT y int)
LANGUAGE plpgsql AS $$
BEGIN
    -- groupid is 0 in coordinator and non-zero in workers, so by using it here
    -- we make sure the procedure is being executed in the worker.
    y := x + (select case groupid when 0 then 1 else 0 end from pg_dist_local_group);
    -- we also make sure that we can run distributed queries in the procedures
    -- that are routed to the workers.
    y := y + (select sum(t1.val + t2.val) from multi_mx_call.mx_call_dist_table_1 t1 join multi_mx_call.mx_call_dist_table_2 t2 on t1.id = t2.id);
END;$$;

-- create another procedure which verifies:
-- 1. we work fine with multiple return columns
-- 2. we work fine in combination with custom types
CREATE PROCEDURE mx_call_proc_custom_types(INOUT x mx_call_enum, INOUT y mx_call_enum)
LANGUAGE plpgsql AS $$
BEGIN
    y := x;
    x := (select case groupid when 0 then 'F' else 'S' end from pg_dist_local_group);
END;$$;

-- Test that undistributed procedures have no issue executing
call multi_mx_call.mx_call_proc(2, 0);
call multi_mx_call.mx_call_proc_custom_types('S', 'A');

-- Mark both procedures as distributed ...
select create_distributed_function('mx_call_proc(int,int)');
select create_distributed_function('mx_call_proc_custom_types(mx_call_enum,mx_call_enum)');

-- We still don't route them to the workers, because they aren't
-- colocated with any distributed tables.
SET client_min_messages TO DEBUG1;
call multi_mx_call.mx_call_proc(2, 0);
call multi_mx_call.mx_call_proc_custom_types('S', 'A');

-- Mark them as colocated with a table. Now we should route them to workers.
call multi_mx_call.colocate_proc_with_table('mx_call_proc', 'mx_call_dist_table_1'::regclass, 1);
call multi_mx_call.colocate_proc_with_table('mx_call_proc_custom_types', 'mx_call_dist_table_enum'::regclass, 1);
call multi_mx_call.mx_call_proc(2, 0);
call multi_mx_call.mx_call_proc_custom_types('S', 'A');

-- We don't allow distributing calls inside transactions
begin;
call multi_mx_call.mx_call_proc(2, 0);
commit;

-- Drop the table colocated with mx_call_proc_custom_types. Now it shouldn't
-- be routed to workers anymore.
SET client_min_messages TO NOTICE;
drop table mx_call_dist_table_enum;
SET client_min_messages TO DEBUG1;
call multi_mx_call.mx_call_proc_custom_types('S', 'A');

-- Make sure we do bounds checking on distributed argument index
-- This also tests that we have cache invalidation for pg_dist_object updates
call multi_mx_call.colocate_proc_with_table('mx_call_proc', 'mx_call_dist_table_1'::regclass, -1);
call multi_mx_call.mx_call_proc(2, 0);
call multi_mx_call.colocate_proc_with_table('mx_call_proc', 'mx_call_dist_table_1'::regclass, 2);
call multi_mx_call.mx_call_proc(2, 0);

-- We don't currently support colocating with reference tables
call multi_mx_call.colocate_proc_with_table('mx_call_proc', 'mx_call_dist_table_ref'::regclass, 1);
call multi_mx_call.mx_call_proc(2, 0);

-- We don't currently support colocating with replicated tables
call multi_mx_call.colocate_proc_with_table('mx_call_proc', 'mx_call_dist_table_replica'::regclass, 1);
call multi_mx_call.mx_call_proc(2, 0);
SET client_min_messages TO NOTICE;
drop table mx_call_dist_table_replica;
SET client_min_messages TO DEBUG1;

call multi_mx_call.colocate_proc_with_table('mx_call_proc', 'mx_call_dist_table_1'::regclass, 1);

-- Test that we handle transactional constructs correctly inside a procedure
-- that is routed to the workers.
CREATE PROCEDURE mx_call_proc_tx(x int) LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO mx_call_dist_table_1 VALUES (x, -1), (x+1, 4);
    COMMIT;
    UPDATE mx_call_dist_table_1 SET val = val+1 WHERE id >= x;
    ROLLBACK;
    -- Now do the final update!
    UPDATE mx_call_dist_table_1 SET val = val-1 WHERE id >= x;
END;$$;

-- before distribution ...
CALL multi_mx_call.mx_call_proc_tx(10);
-- after distribution ...
select create_distributed_function('mx_call_proc_tx(int)', '$1', 'mx_call_dist_table_1');
CALL multi_mx_call.mx_call_proc_tx(20);
SELECT id, val FROM mx_call_dist_table_1 ORDER BY id, val;

-- Test that we properly propagate errors raised from procedures.
CREATE PROCEDURE mx_call_proc_raise(x int) LANGUAGE plpgsql AS $$
BEGIN
    RAISE WARNING 'warning';
    RAISE EXCEPTION 'error';
END;$$;
select create_distributed_function('mx_call_proc_raise(int)', '$1', 'mx_call_dist_table_1');
call multi_mx_call.mx_call_proc_raise(2);


-- Test that we don't propagate to non-metadata worker nodes
select stop_metadata_sync_to_node('localhost', :worker_1_port);
select stop_metadata_sync_to_node('localhost', :worker_2_port);
call multi_mx_call.mx_call_proc(2, 0);
SET client_min_messages TO NOTICE;
select start_metadata_sync_to_node('localhost', :worker_1_port);
select start_metadata_sync_to_node('localhost', :worker_2_port);
SET client_min_messages TO DEBUG1;

--
-- Test non-const parameter values
--
CREATE FUNCTION mx_call_add(int, int) RETURNS int
    AS 'select $1 + $2;' LANGUAGE SQL IMMUTABLE;
SELECT create_distributed_function('mx_call_add(int,int)', '$1');

-- non-const distribution parameters cannot be pushed down
call multi_mx_call.mx_call_proc(2, mx_call_add(3, 4));

-- non-const parameter can be pushed down
call multi_mx_call.mx_call_proc(multi_mx_call.mx_call_add(3, 4), 2);

-- volatile parameter cannot be pushed down
call multi_mx_call.mx_call_proc(floor(random())::int, 2);

--
-- clean-up
--
reset client_min_messages;
reset citus.shard_replication_factor;
reset citus.replication_model;
reset search_path;

\set VERBOSITY terse
drop schema multi_mx_call cascade;
\set VERBOSITY default
