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
-module(etsdb_socket_server).
-behaviour(gen_server).

-export([start_link/0, set_socket/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("etsdb_client_messages.hrl").
-include("etsdb_request.hrl").

-define(DEFAULT_TIMEOUT, 60000).

-record(state, {
          socket
         }).


start_link() ->
    gen_server:start_link(?MODULE, [], []).

set_socket(Pid, Socket) ->
    gen_server:call(Pid, {set_socket, Socket}, infinity).

init([]) ->
    {ok, #state{}}.

handle_call({set_socket, Socket}, _From, State) ->
    inet:setopts(Socket, [{active, once}, {packet, 4}]),
    {reply, ok, State#state{socket = Socket}}.


handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp_closed, Socket}, State=#state{socket=Socket}) ->
    {stop, normal, State};
handle_info({tcp_error, Socket, _Reason}, State=#state{socket=Socket}) ->
    {stop, normal, State};
handle_info({tcp, _Sock,MsgData}, State=#state{
                                               socket=Socket}) ->
   NewState = process_message(MsgData, State),
   inet:setopts(Socket, [{active, once}]),
   {noreply, NewState};

handle_info(Message, State) ->
    %% Throw out messages we don't care about, but log them
    lager:error("Unrecognized message ~p", [Message]),
    {noreply, State}.

terminate(Reason, _State) ->
	lager:error("Terminating socket server ~p",[Reason]),
    ok.

code_change(_OldVsn,State,_Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal functions
%% ===================================================================
process_message(<<Type:8/integer,RequestData/binary>>,State)->
	process_message(Type,RequestData,State);
process_message(_,#state{socket=Sock}=State)->
	gen_tcp:send(Sock,<<1:8/integer>>),
	State.
process_message(?ETSDB_CLIENT_PUT,BatchData,#state{socket=Sock}=State)->
	case catch get_batch(BatchData,[]) of
		{ok,ErlData}->
			case etsdb_put:put(etsdb_tkb,ErlData,?DEFAULT_TIMEOUT) of
				#etsdb_store_res_v1{}=Res->
					{Size,ResData} = make_store_result(Res),
					send_reply(Sock,?ETSDB_CLIENT_OK,Size,ResData);
				Else ->
					lager:error("error ~p",[Else]),
					send_reply(Sock,?ETSDB_CLIENT_RUNTIME_ERROR,Else)
			end;
		Else->
			lager:error("Bad request from client ~p",[Else]),
			send_reply(Sock,?ETSDB_CLIENT_UNKNOWN_DATA_FROMAT)
	end,
	State;
process_message(?ETSDB_CLIENT_SCAN,<<ID:64/integer,From:64/integer,To:64/integer>>,#state{socket=Sock}=State)->
	case etsdb_get:scan(etsdb_tkb,{ID,From},{ID,To}) of
		{ok,Data}->
			{Size,Data1} = make_scan_result(Data),
			send_reply(Sock,?ETSDB_CLIENT_OK,Size,Data1);
		{error,Else} ->
			lager:error("error ~p",[Else]),
			send_reply(Sock,?ETSDB_CLIENT_RUNTIME_ERROR,Else)
	end,
	State;
process_message(?ETSDB_CLIENT_SCAN,_,#state{socket=Sock}=State)->
	send_reply(Sock,?ETSDB_CLIENT_UNKNOWN_DATA_FROMAT),
	State;
process_message(_Type,_BatchData,#state{socket=Sock}=State)->
	send_reply(Sock,?ETSDB_CLIENT_UNKNOWN_REQ_TYPE),
	State.

get_batch(<<>>,Acc)->
	{ok,lists:reverse(Acc)};
get_batch(<<DataSize:32/unsigned-integer,ID:64/integer,Time:64/integer,Data:DataSize/binary,Tail/binary>>,Acc)->
	get_batch(Tail,[{{ID,Time},Data}|Acc]);
get_batch(_Else,_Acc)->
	{error,bad_format}.

send_reply(Sock,Code)->
	gen_tcp:send(Sock,<<1:32/unsigned-integer,Code:8/integer>>).

send_reply(Sock,Code,Data) when not is_binary(Data)->
	PrintedData = list_to_binary(io_lib:format("~p",[Data])),
	send_reply(Sock,Code,PrintedData);
send_reply(Sock,Code,Data)->
	Size = 1+size(Data),
	gen_tcp:send(Sock,[<<Size:32/unsigned-integer,Code:8/integer>>,Data]).

send_reply(Sock,Code,Size,Data)->
	PacketSize = 1+Size,
	gen_tcp:send(Sock,[<<PacketSize:32/unsigned-integer,Code:8/integer>>,Data]).

make_scan_result(Res)->
	make_scan_result(Res,0,[]).
make_scan_result([],Size,Acc)->
	{Size,Acc};
make_scan_result([{{ID,Time},Data}|T],Size,Acc)->
	DataSize = size(Data),
	Res = [<<DataSize:32/unsigned-integer,ID:64/integer,Time:64/integer>>,Data],
	make_scan_result(T,Size+DataSize+20,[Res|Acc]).

make_store_result(#etsdb_store_res_v1{count=C,error_count=E,errors=Errors})->
	ErrorsData = case Errors of
					 []->
						 <<>>;
					 _->
						 list_to_binary(io_lib:format("~p",[Errors]))
				 end,	
	{64+size(ErrorsData),[<<C:32/integer,E:32/integer>>,ErrorsData]}.