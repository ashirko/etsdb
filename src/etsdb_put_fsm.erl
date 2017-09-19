%% -------------------------------------------------------------------
%%
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

-module(etsdb_put_fsm).

-behaviour(gen_fsm).

-export([start_link/5]).
-export([start_link/6]).


-export([init/1, execute/2,wait_result/2,prepare/2, handle_event/3,
     handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-record(results,{num_ok=0,num_fail=0,ok_quorum=0,fail_quorum=0,errors=[]}).
-record(state, {result_hadler,preflist,partition,data,timeout,bucket,results,req_ref,to_delete}).

start_link(ResultHandler,Partition,Bucket,Data,Timeout) ->
%%    lager:info("test_data 3: ~p", [{Bucket, Data}]),
    start_link(ResultHandler,Partition,Bucket,Data,Timeout,false).

start_link(ResultHandler,Partition,Bucket,Data,Timeout,ToDelete) ->
    gen_fsm:start_link(?MODULE, [ResultHandler,Partition,Bucket,Data,Timeout,ToDelete], []).

init([ResultHandler,Partition,Bucket,Data,Timeout,ToDelete]) ->
    {ok,prepare, #state{result_hadler = ResultHandler,partition=Partition,bucket=Bucket,
        timeout=Timeout,data=Data,to_delete=ToDelete},0}.

prepare(timeout, #state{result_hadler  = ResultHandler,partition=Partition,bucket=Bucket}=StateData) ->
    WriteCount = Bucket:w_val(),
    VNodeHash = etsdb_util:hash_for_partition(Partition),
    case preflist(VNodeHash,WriteCount) of
        {error,Error}->
            reply_to_caller(ResultHandler,{error,Error}),
            {stop,normal,StateData};
        Preflist when length(Preflist)==WriteCount->
            NumOk = Bucket:w_quorum(),
            NumFail = WriteCount-NumOk+1,
            {next_state,execute,StateData#state{preflist=Preflist,results=#results{ok_quorum=NumOk,fail_quorum=NumFail}},0};
        Preflist->
            lager:error("Insufficient vnodes in preflist ~p must be ~p",[length(Preflist),WriteCount]),
            reply_to_caller(ResultHandler,{error,insufficient_vnodes}),
            {stop,normal,StateData}
    end.
execute(timeout, #state{preflist=Preflist,data=Data,bucket=Bucket,timeout=Timeout,to_delete=true}=StateData) ->
    Ref = make_ref(),
    etsdb_vnode:delete_records(Ref,Preflist,Bucket,Data),
    {next_state,wait_result, StateData#state{data=undefined,req_ref=Ref},Timeout};
execute(timeout, #state{preflist=Preflist,data=Data,bucket=Bucket,timeout=Timeout}=StateData) ->
    Ref = make_ref(),
%%    lager:info("test_data 4: ~p", [{Bucket, Data}]),
    etsdb_vnode:put_external(Ref,Preflist,Bucket,Data),
%%    lager:info("test_data 5: ~p", [{Bucket, Data}]),
    {next_state,wait_result, StateData#state{data=undefined,req_ref=Ref},Timeout}.


wait_result({w,Index,ReqID,Res}=Msg,#state{result_hadler = ResaultHandler,results=Results,req_ref=ReqID,timeout=Timeout}=StateData) ->
    case add_result(Index, Res, Results) of
        #results{}=NewResult->
            {next_state,wait_result, StateData#state{results=NewResult},Timeout};
        ResultToReply->
             reply_to_caller(ResaultHandler,ResultToReply),
             {stop,normal,StateData}
    end;
wait_result({d,_,_,_},State)->
    {stop,normal,State};
wait_result(timeout,#state{result_hadler = ResaultHandler}=StateData) ->
    lager:info("timeout in state wait_result"),
    reply_to_caller(ResaultHandler,{error,timeout}),
    {stop,normal,StateData}.


handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event(_Event, _From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.

handle_info(_Info, StateName, StateData) ->
    {next_state, StateName, StateData}.


terminate(_Reason, _StateName, _StatData) ->
    ok.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

reply_to_caller(Fun,Reply) when is_function(Fun)->
    Fun(Reply);
reply_to_caller({raw,Ref,To},Reply)->
    To ! {Ref,Reply}.


preflist(Partition,WVal)->
    etsdb_apl:get_apl(Partition,WVal).


add_result(_,ok,#results{num_ok=Count,ok_quorum=Quorum}=Results)->
    Count1 = Count+1,
    if
        Count1==Quorum->
            ok;
        true->
            Results#results{num_ok=Count1}
    end;
add_result(Index,Res,#results{num_fail=Count,fail_quorum=Quorum,errors=Errs}=Results)->
    lager:error("Filed store to ~p - ~p",[Index,Res]),
    Count1 = Count+1,
    if
        Count1==Quorum->
            {error,fail};
        true->
            Results#results{num_fail=Count1,errors=[{Index,Res}|Errs]}
    end.
