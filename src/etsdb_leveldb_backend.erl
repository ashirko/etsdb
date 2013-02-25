%% -------------------------------------------------------------------
%%
%% etsdb_leveldb_backend backend: leveldb backend for etsdb. 
%%
%% Copyright (c) Dreyk.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

%% @doc it's ets table backend.
-module(etsdb_leveldb_backend).

-record(state, {ref :: reference(),
                data_root :: string(),
                open_opts = [],
                config,
                read_opts = [],
                write_opts = [],
                fold_opts = [{fill_cache, false}]
               }).

-export([init/2,
		 save/3]).

init(Partition, Config) ->
    %% Initialize random seed
    random:seed(now()),

    %% Get the data root directory
    DataDir = filename:join(app_helper:get_prop_or_env(data_root, Config, eleveldb),
                            integer_to_list(Partition)),

    %% Initialize state
    S0 = init_state(DataDir, Config),
    case open_db(S0) of
        {ok, State} ->
            {ok, State};
        {error, Reason} ->
            {error, Reason}
    end.

save(Bucket,Data,#state{ref=Ref,write_opts=WriteOpts}=State) ->
    Updates = [{put,Key, Val}||{Key,Val}<-Bucket:serialize(Data,?MODULE)],
    case eleveldb:write(Ref, Updates,WriteOpts) of
        ok ->
            {ok, State};
        {error, Reason} ->
            {error, Reason, State}
    end.

init_state(DataRoot, Config) ->
    %% Get the data root directory
    filelib:ensure_dir(filename:join(DataRoot, "dummy")),

    %% Merge the proplist passed in from Config with any values specified by the
    %% eleveldb app level; precedence is given to the Config.
    MergedConfig = orddict:merge(fun(_K, VLocal, _VGlobal) -> VLocal end,
                                 orddict:from_list(Config), % Local
                                 orddict:from_list(application:get_all_env(eleveldb))), % Global

    %% Use a variable write buffer size in order to reduce the number
    %% of vnodes that try to kick off compaction at the same time
    %% under heavy uniform load...
    WriteBufferMin = config_value(write_buffer_size_min, MergedConfig, 30 * 1024 * 1024),
    WriteBufferMax = config_value(write_buffer_size_max, MergedConfig, 60 * 1024 * 1024),
    WriteBufferSize = WriteBufferMin + random:uniform(1 + WriteBufferMax - WriteBufferMin),

    %% Update the write buffer size in the merged config and make sure create_if_missing is set
    %% to true
    FinalConfig = orddict:store(write_buffer_size, WriteBufferSize,
                                orddict:store(create_if_missing, true, MergedConfig)),

    %% Parse out the open/read/write options
    {OpenOpts, _BadOpenOpts} = eleveldb:validate_options(open, FinalConfig),
    {ReadOpts, _BadReadOpts} = eleveldb:validate_options(read, FinalConfig),
    {WriteOpts, _BadWriteOpts} = eleveldb:validate_options(write, FinalConfig),

    %% Use read options for folding, but FORCE fill_cache to false
    FoldOpts = lists:keystore(fill_cache, 1, ReadOpts, {fill_cache, false}),

    %% Warn if block_size is set
    SSTBS = proplists:get_value(sst_block_size, OpenOpts, false),
    BS = proplists:get_value(block_size, OpenOpts, false),
    case BS /= false andalso SSTBS == false of
        true ->
            lager:warning("eleveldb block_size has been renamed sst_block_size "
                          "and the current setting of ~p is being ignored.  "
                          "Changing sst_block_size is strongly cautioned "
                          "against unless you know what you are doing.  Remove "
                          "block_size from app.config to get rid of this "
                          "message.\n", [BS]);
        _ ->
            ok
    end,

    %% Generate a debug message with the options we'll use for each operation
    lager:debug("Datadir ~s options for LevelDB: ~p\n",
                [DataRoot, [{open, OpenOpts}, {read, ReadOpts}, {write, WriteOpts}, {fold, FoldOpts}]]),
    #state { data_root = DataRoot,
             open_opts = OpenOpts,
             read_opts = ReadOpts,
             write_opts = WriteOpts,
             fold_opts = FoldOpts,
             config = FinalConfig }.

open_db(State) ->
    RetriesLeft = app_helper:get_env(riak_kv, eleveldb_open_retries, 30),
    open_db(State, max(1, RetriesLeft), undefined).

open_db(_State0, 0, LastError) ->
    {error, LastError};
open_db(State0, RetriesLeft, _) ->
    case eleveldb:open(State0#state.data_root, State0#state.open_opts) of
        {ok, Ref} ->
            {ok, State0#state { ref = Ref }};
        %% Check specifically for lock error, this can be caused if
        %% a crashed vnode takes some time to flush leveldb information
        %% out to disk.  The process is gone, but the NIF resource cleanup
        %% may not have completed.
        {error, {db_open, OpenErr}=Reason} ->
            case lists:prefix("IO error: lock ", OpenErr) of
                true ->
                    SleepFor = app_helper:get_env(riak_kv, eleveldb_open_retry_delay, 2000),
                    lager:debug("Leveldb backend retrying ~p in ~p ms after error ~s\n",
                                [State0#state.data_root, SleepFor, OpenErr]),
                    timer:sleep(SleepFor),
                    open_db(State0, RetriesLeft - 1, Reason);
                false ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @private
config_value(Key, Config, Default) ->
    case orddict:find(Key, Config) of
        error ->
            Default;
        {ok, Value} ->
            Value
    end.