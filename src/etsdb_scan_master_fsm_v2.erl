%% Author: gunin
%% Created: Nov 28, 2013
%% Description: TODO: Add description to etsdb_scan_master_fsm
-module(etsdb_scan_master_fsm_v2).
-behaviour(gen_fsm).

-export([start_link/3,start_link/4,join_data/3]).


-export([init/1, prepare/2,execute/2,wait_result/2, handle_event/3,
     handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-record(ack,{num_ok=0,num_fail=0,ok_quorum=0,fail_quorum=0}).
-record(state, {caller,scan_req,local_scaners,timeout,req_ref,ack_data,data,stream}).

-include("etsdb_request.hrl").

start_link(Caller,ScanReq,Timeout) ->
    start_link(Caller,ScanReq,undefined,Timeout).
start_link(Caller,ScanReq,Stream,Timeout) ->
    gen_fsm:start_link(?MODULE, [Caller,ScanReq,Stream,Timeout], []).

init([Caller,ScanReq,Stream,Timeout]) ->
    {ok,prepare, #state{caller=Caller,scan_req=ScanReq,timeout=Timeout,stream = Stream},0}.


prepare(timeout, #state{caller=Caller,scan_req=ScanReq}=StateData) ->
    case ScanReq#scan_req.pscan of
        #pscan_req{partition=all}=PScan->
            {ok, Ring} = riak_core_ring_manager:get_my_ring(),
            AllOwners = riak_core_ring:all_owners(Ring),
            PscanAll = lists:foldl(fun({Index,_},Acc)->
                                        [PScan#pscan_req{partition={vnode,Index}}|Acc]
                                        end,[],AllOwners),
            prepare(StateData#state{scan_req=ScanReq#scan_req{pscan=PscanAll}});
        #pscan_req{}=One->
            prepare(StateData#state{scan_req=ScanReq#scan_req{pscan=[One]}});
        List when is_list(List)->
           prepare(StateData);
        _->
            reply_to_caller(Caller,{error,bad_request}),
            {stop,normal,StateData}
    end.
prepare(#state{caller=Caller,scan_req=ScanReq}=StateData) ->
    {ok,Ring} = riak_core_ring_manager:get_my_ring(),
    {ByPartiotion,AckData} = lists:foldl(fun(#pscan_req{partition=Partiotion,n_val=NVal,quorum=Quorum}=Scan,{ScanAcc,AckAcc})->
                                                 case Partiotion of
                                                     {vnode,VnodeIdx}->
                                                         VnodeIdx;
                                                     _->
                                                         PartitionIdx = crypto:hash(sha,Partiotion),
                                                         VnodeIdx=riak_core_ring:responsible_index(PartitionIdx,Ring)
                                                 end,
                                                 AckRef = erlang:make_ref(),
                                                 FailQuorum = NVal-Quorum+1,
                                                 {[{{VnodeIdx,NVal},{AckRef,Scan}}|ScanAcc],
                                                  [{AckRef,#ack{ok_quorum=Quorum,fail_quorum=FailQuorum}}|AckAcc]} end,{[],[]},ScanReq#scan_req.pscan),
    ByPartiotion1 = etsdb_util:reduce_orddict(fun merge_scan1/2,lists:keysort(1,ByPartiotion)),
    case pscan(ByPartiotion1,[]) of
        {error,Error}->
            reply_to_caller(Caller,{error,Error}),
            {stop,normal,StateData};
        ReqNodes->
            lager:info("ReqNodes length: ~p; data: ~p", [length(ReqNodes), ReqNodes]),
            {next_state,execute,StateData#state{local_scaners=ReqNodes,ack_data=lists:ukeysort(1,AckData)},0}
    end.

merge_scan1(Data,'$start') when is_list(Data)->
    Data;
merge_scan1(Data,'$start')->
    [Data];
merge_scan1('$end',Acc)->
    Acc;
merge_scan1(Data,Acc) when is_list(Data)->
    Acc++Data;
merge_scan1(Data,Acc)->
    [Data|Acc].

pscan([],Requests)->
    etsdb_util:reduce_orddict(fun merge_req_by_node/2,lists:keysort(1,Requests));
pscan([{{VnodeIdx,NVal},Scans}|Tail],Requests)->
   Hash = etsdb_util:hash_for_partition(VnodeIdx),
   case preflist(Hash,NVal) of
        {error,Error}->
            {error,Error};
        PrefList when is_list(PrefList) andalso length(PrefList)==NVal->
            Requests1 = lists:foldl(fun({VNode,Node},Acc)->
                                [{Node,{VNode,Scans}}|Acc]
                        end,Requests,PrefList),
            pscan(Tail, Requests1);
        _Preflist->
            {error,insufficient_vnodes}
    end.
merge_req_by_node(Data,'$start')->
    [Data];
merge_req_by_node('$end',Acc)->
    etsdb_util:reduce_orddict(fun merge_scan1/2,lists:keysort(1,Acc));
merge_req_by_node(Data,Acc)->
    [Data|Acc].

execute(timeout, #state{local_scaners=ToScan,scan_req=ScanReq,timeout=Timeout,caller=Caller,stream = Stream}=StateData) ->
    Ref = make_ref(),
    case start_local_fsm(ToScan,Ref,ScanReq#scan_req{pscan=undefined},Stream,Timeout,[]) of
        {error,Error,Started}->
            reply_to_caller(Caller,{error,Error}),
            stop_started(Started),
            {stop,Error,StateData};
        Started->
            {next_state,wait_result, StateData#state{req_ref=Ref,local_scaners=Started,data=[]},Timeout}
    end.

start_local_fsm([],_Ref,_ScanReq,_Stream,_Timeout,Monitors)->
    Monitors;
start_local_fsm([{Node,Requests}|Tail],Ref,ScanReq,Stream,Timeout,Monitors)->
    lager:info("start_local_fsm on node ~p; requests ~p", [Node, Requests]),
    case etsdb_scan_local_fsm_v2:start(Ref,Node) of
        {ok,Pid}->
             MRef = erlang:monitor(process,Pid),
             etsdb_scan_local_fsm_v2:ack(Pid,ScanReq#scan_req{pscan=Requests},Stream,Timeout),
             start_local_fsm(Tail,Ref,ScanReq,Stream,Timeout,[{MRef,Pid}|Monitors]);
        Else->
            lager:error("Can't start local scan on ~p reason ~p",[Node,Else]),
            {error,insufficient_nodes,Monitors}
    end.

stop_started(Started)->
    lists:foreach(fun({_,Pid})->
                          etsdb_scan_local_fsm_v2:stop(Pid) end,Started).

wait_result(timeout,#state{caller=Caller,local_scaners=Scaners}=StateData) ->
    lager:info("wait results 1. Caller ~p; local_scaners: ~p", [Caller, Scaners]),
     reply_to_caller(Caller,{error,timeout}),
     stop_started(Scaners),
     {stop,normal,StateData#state{data=undefined,local_scaners=[]}};

wait_result({local_scan,ReqID,From,Error,Ack,LocalData},#state{req_ref=ReqID}=StateData) ->
    lager:error("wait results 2. Fail some scan on ~p reason ~p",[node(From),Error]),
    receive_ack(From,Ack,LocalData,StateData);
wait_result({local_scan,ReqID,From,Ack,LocalData},#state{req_ref=ReqID}=StateData) ->
    lager:info("wait results 3. ReqID ~p; From: ~p; Ask: ~p;  ReqID: ~p; local_data: ~p", [ReqID, From, Ack, ReqID, LocalData]),
    lager:info("wait results 3-1. StateData: ~p", [StateData]),
    receive_ack(From,Ack,LocalData,StateData);
wait_result({local_scan,ReqID,From,Error},#state{caller=Caller,req_ref=ReqID,local_scaners=Scaners}=StateData) ->
    lager:error("wait results 4. fail scan on ~p reason ~p",[node(From),Error]),
    NewScaners = lists:keydelete(From, 2,Scaners),
    reply_to_caller(Caller,Error),
    stop_started(NewScaners),
    {stop,normal,StateData#state{data=undefined,local_scaners=[]}}.

receive_ack(From,Ack,LocalData,#state{caller=Caller,scan_req=Scan,local_scaners=Scaners,ack_data=AckData,data=Data}=StateData)->
    NewScaners = lists:keydelete(From,2,Scaners),
%%    lager:info("receive_ack 1. Ack: ~p; AckData: ~p, LocalData: ~p; Data: ~p", [Ack, AckData, LocalData, Data]),
    case ack(Ack,AckData) of
        {error,Error}->
%%            lager:info("receive_ack 2. Error: ~p", [Error]),
            reply_to_caller(Caller,{error,Error}),
            stop_started(NewScaners),
            {stop,normal,StateData#state{data=undefined,local_scaners=[]}};
        []->
%%            lager:info("receive_ack 3"),
            NewData = join_data(Scan#scan_req.join_fun,LocalData,Data),
            reply_to_caller(Caller,{ok,final_data(Scan#scan_req.final_fun,NewData)}),
            stop_started(NewScaners),
            {stop,normal,StateData#state{data=undefined,local_scaners=[]}};
        NewAckData->
%%            lager:info("receive_ack 4. NewAckData: ~p", [NewAckData]),
            NewData = join_data(Scan#scan_req.join_fun,LocalData,Data),
%%            lager:info("receive_ack 5. NewAckData: ~p", [NewData]),
            {next_state,wait_result, StateData#state{data=NewData,ack_data=NewAckData,local_scaners=NewScaners},StateData#state.timeout}
    end.

ack([],AckData)->
    AckData;
ack([{Ref,Result}|Tail],AckData)->
    case orddict:find(Ref,AckData) of
        {ok,#ack{num_ok=NumOk,num_fail=NumFail,fail_quorum=FailQ,ok_quorum=OkQ}=Ack}->
            case Result of
                ok->
                    NumOk1=NumOk+1,
                    if
                        NumOk1==OkQ->
                            ack(Tail,orddict:erase(Ref,AckData));
                        true->
                            ack(Tail,orddict:store(Ref,Ack#ack{num_ok=NumOk1},AckData))
                    end;
                _->
                    NumFail1=NumFail+1,
                    if
                        NumFail1==FailQ->
                            {error,quorum_fail};
                        true->
                            ack(Tail,orddict:store(Ref,Ack#ack{num_fail=NumFail1},AckData))
                    end
            end;
        _->
            ack(Tail,AckData)
    end.

join_data({M,F,A},NewData,OldData)->
    apply(M,F,[NewData,OldData|A]);
join_data(Fun,NewData,OldData)->
    Fun(NewData,OldData).
final_data({M,F,A},Data)->
    apply(M,F,[Data|A]);
final_data(Fun,Data) when is_function(Fun)->
    Fun(Data);
final_data(_Fun,Data)->
    Data.

handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event(_Event, _From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.

handle_info({'DOWN',MonitorRef, _Type, Object, Info}, StateName, #state{caller=Caller,local_scaners=LocalScaners}=StateData) ->
    case lists:keymember(MonitorRef,1,LocalScaners) of
        true->
            Node = if
                       is_pid(Object)->
                           erlang:node(Object);
                       true->
                           Object
                   end,
            lager:error("Fail scan on ~p reason ~p",[Node,Info]),
            NewScaners = lists:keydelete(MonitorRef, 1,LocalScaners),
            reply_to_caller(Caller,{error,local_failed}),
            stop_started(NewScaners),
            {stop,normal,StateData#state{data=undefined,local_scaners=[]}};
        _->
            {next_state, StateName, StateData,StateData#state.timeout}
    end;
handle_info(_Info, StateName, StateData) ->
    {next_state, StateName, StateData}.


terminate(_Reason, _StateName, _StatData) ->
    ok.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

reply_to_caller({raw,Ref,To},Reply)->
    To ! {Ref,Reply}.

preflist(Partition,WVal)->
    etsdb_apl:get_apl(Partition,WVal).
