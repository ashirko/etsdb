%% Author: gunin
%% Created: Nov 28, 2013
%% Description: TODO: Add description to etsdb_scan
-module(etsdb_scan).

%%
%% Include files
%%

%%
%% Exported Functions
%%
-export([scan/2,stream/3, stream_v2/3]).

stream(Stream,ScanReq,Timeout)->
    exec(Stream,ScanReq,Timeout).
stream_v2(Stream,ScanReq,Timeout)->
    exec_v2(Stream,ScanReq,Timeout).
scan(ScanReq,Timeout)->
    exec(undefined,ScanReq,Timeout).

exec(Stream,ScanReq,Timeout)->
    ReqRef = make_ref(),
    Me = self(),
    etsdb_scan_master_fsm:start_link({raw,ReqRef,Me}, ScanReq,Stream,Timeout),
    case wait_for_results(ReqRef,client_wait_timeout(Timeout)) of
        {ok,Res} when is_list(Res)->
            {ok,Res};
        Else->
            lager:error("Bad scan responce for ~p used timeout ~p",[ScanReq,Timeout]),
            etsdb_util:make_error_response(Else)
    end.

exec_v2(Stream,ScanReq,Timeout)->
    ReqRef = make_ref(),
    Me = self(),
    etsdb_scan_master_fsm_v2:start_link({raw,ReqRef,Me}, ScanReq,Stream,Timeout),
    case wait_for_results(ReqRef,client_wait_timeout(Timeout)) of
        {ok,Res} when is_list(Res)->
            {ok,Res};
        Else->
            lager:error("Bad scan responce for ~p used timeout ~p",[ScanReq,Timeout]),
            etsdb_util:make_error_response(Else)
    end.

wait_for_results(ReqRef,Timeout)->
    receive 
        {ReqRef,Res}->
            Res
    after Timeout->
            {error,timeout}
    end.

%%Add 50ms to operation timeout
client_wait_timeout(Timeout)->
    Timeout + 50.