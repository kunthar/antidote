-module(bcounter_mgr).
-behaviour(gen_server).

-export([start_link/0,
         generate_downstream/3,
         process_transfer/2
        ]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-include("antidote.hrl").
-include("inter_dc_repl.hrl").

-record(state, {req_queue, last_transfers, transfer_timer}).
-define(GRACE_PERIOD, 500000). %Microsecons
-define(TRANSFER_PERIOD, 5000). %Milliseconds

%% ===================================================================
%% Public API
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    lager:info("Started Bounded counter manager at node ~p", [node()]),
    Timer=erlang:send_after(?TRANSFER_PERIOD, self(), transfer_periodic),
    {ok, #state{req_queue=orddict:new(), transfer_timer=Timer, last_transfers=orddict:new()}}.

generate_downstream(Key, {{decrement, _}=Operation, _Actor}, BCounter) ->
    gen_server:call(?MODULE, {consume, Key, Operation, BCounter});

generate_downstream(Key, {{increment, _}=Operation, _Actor}, BCounter) ->
    gen_server:call(?MODULE, {generate, Key, Operation, BCounter});

generate_downstream(_Key, {Operation, _Actor}, BCounter) ->
    MyId = dc_meta_data_utilities:get_my_dc_id(),
    crdt_bcounter:generate_downstream(Operation, MyId, BCounter).

process_transfer(Key, {{transfer, _, _}=Operation, _Actor}) ->
    gen_server:cast(?MODULE, {transfer, Key, Operation}).

%% ===================================================================
%% Callbacks
%% ===================================================================

handle_cast({transfer, Key, {_,_,To}=Operation}, #state{last_transfers=LT}=State) ->
    NewLT = clear_timeouts(LT),
    case can_transfer(Key, To, NewLT) of
        true ->
            Result = rpc:call(node(), antidote, append, [Key, crdt_bcounter, {Operation, dc}]),
            lager:info("Transfer Result ~p.",[Result]),
            {noreply, State#state{last_transfers=orddict:store({Key, To}, erlang:now(), NewLT)}};
        _ ->
            {noreply, State#state{last_transfers=NewLT}}
    end.

can_transfer(Key, To, LastTransfers) ->
    MyId = dc_meta_data_utilities:get_my_dc_id(),
    case To == MyId of
        false ->
            CurrTime = erlang:now(),
            case orddict:find({Key, To}, LastTransfers) of
                {ok, Timeout} ->
                    case timer:now_diff(Timeout,CurrTime) < ?GRACE_PERIOD of
                        true -> true;
                        _ -> false
                    end;
                error -> true
            end;
        true -> false
    end
    .

clear_timeouts(LastTransfers) ->
    CurrTime = erlang:now(),
    orddict:filter(
      fun(_, Timeout) ->
              timer:now_diff(Timeout,CurrTime) < ?GRACE_PERIOD end, LastTransfers).

handle_call({_IncOrDec, Key, {_,Amount}=Operation, BCounter}, _From, #state{req_queue=RQ}=State) ->
    MyId = dc_meta_data_utilities:get_my_dc_id(),
    case crdt_bcounter:generate_downstream(Operation, MyId, BCounter) of
        {error, no_permissions} = FailedResult ->
            Available = crdt_bcounter:local_permissions(MyId, BCounter),
            UpdtQueue=queue_request(Key, Amount - Available, RQ),
            {reply, FailedResult, State#state{req_queue=UpdtQueue}};
        Result -> {reply, Result, State}
    end.

handle_info(transfer_periodic, #state{req_queue=RQ,transfer_timer=OldTimer}=State) ->
    erlang:cancel_timer(OldTimer),
    lager:info("Periodic Resources Transfer ~p.",[RQ]),
    orddict:fold(
      fun(Key, Queue, Accum) ->
              case Queue of
                  [] -> Accum;
                  Queue ->
                      lager:info("Processing queue ~p for key ~p.",[Queue,Key]),
                      RequiredSum = lists:foldl(fun({Request, _Timeout}, Sum) ->
                                                        Sum + Request end, 0, Queue),
                      {ok,Obj} = antidote:read(Key, crdt_bcounter),
                      PrefList= pref_list(Obj),
                      Remaining = lists:foldl(
                                    fun({RemoteId, AvailableRemotely}, Remaining0) ->
                                            case Remaining0 > 0 of
                                                true when AvailableRemotely > 0 ->
                                                    ToRequest = case AvailableRemotely - Remaining0 >= 0 of
                                                                    true -> Remaining0;
                                                                    false -> AvailableRemotely
                                                                end,
                                                    lager:info("Going to Request ~p to ~p.", [ToRequest, RemoteId]),
                                                    Remaining0 - ToRequest;
                                                _ -> 0
                                            end
                                    end, RequiredSum, PrefList),
                      lager:info("Remaining required resources after transfer request: ~p.", [Remaining]),
                      queue_request(Key, Remaining, Accum)
              end
      end, orddict:new(), RQ),
    NewTimer=erlang:send_after(?TRANSFER_PERIOD, self(), transfer_periodic),
    {noreply,State#state{transfer_timer=NewTimer}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

queue_request(Key, Amount, RequestsQueue) ->
    lager:info("Current requests Queue ~p", [RequestsQueue]),
    QueueForKey = case orddict:find(Key, RequestsQueue) of
                      {ok, Value} -> Value;
                      error -> []
                  end,
    CurrTime = erlang:now(),
    orddict:store(Key, [{Amount, CurrTime} | QueueForKey], RequestsQueue).

pref_list(Obj) ->
    MyId = dc_meta_data_utilities:get_my_dc_id(),
    OtherDCDescriptors = dc_meta_data_utilities:get_dc_descriptors(),
    OtherDCIds = lists:foldl(fun(#descriptor{dcid=Id}, IdsList) ->
                                     case Id == MyId of
                                         true -> IdsList;
                                         false -> [Id | IdsList]
                                     end
                             end, [], OtherDCDescriptors),
    lists:sort(
      fun({_, A}, {_, B}) -> A =< B end,
      lists:foldl(fun(Id, Accum) ->
                          Permissions = crdt_bcounter:local_permissions(Id, Obj),
                          [{Id, Permissions} | Accum]
                  end, [], OtherDCIds)).


