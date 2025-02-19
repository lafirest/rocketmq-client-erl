%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(rocketmq_producers).

-include("rocketmq.hrl").

%% APIs
-export([start_link/4]).
%% gen_server callbacks
-export([ code_change/3
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , init/1
        , terminate/2
        ]).

-export([ start_supervised/4
        , stop_supervised/1
        ]).

-export([ pick_producer/1
        , pick_producer/2
        ]).

-record(state, {topic,
                client_id,
                workers,
                queue_nums,
                producer_opts,
                producers = #{},
                producer_group,
                broker_datas,
                ref_topic_route_interval = 5000}).

-define(RESTART_INTERVAL, 3000).

-type queue_number() :: non_neg_integer().
-type queue_count() :: pos_integer().
-type clientid() :: atom().
-type topic() :: binary().
-type partitioner() :: roundrobin | key_dispatch.
-type producer_group() :: binary().
-type producers() :: #{ client := clientid()
                      , topic := topic()
                      , workers := ets:table()
                      , queue_nums := queue_count()
                      , partitioner := partitioner()
                      }.
-type producer_opts() :: map().
-type produce_context() :: #{ key => term()
                            , any() => term()
                            }.

-export_type([ producers/0
             , produce_context/0
             ]).

-spec start_supervised(clientid(), producer_group(), topic(), producer_opts()) -> {ok, producers()}.
start_supervised(ClientId, ProducerGroup, Topic, ProducerOpts) ->
  {ok, Pid} = rocketmq_producers_sup:ensure_present(ClientId, ProducerGroup, Topic, ProducerOpts),
  {QueueCount, Workers} = gen_server:call(Pid, get_workers, infinity),
  {ok, #{client => ClientId,
         topic => Topic,
         workers => Workers,
         queue_nums => QueueCount,
         partitioner => maps:get(partitioner, ProducerOpts, roundrobin)
        }}.

stop_supervised(#{client := ClientId, workers := Workers}) ->
  rocketmq_producers_sup:ensure_absence(ClientId, Workers).

-spec pick_producer(producers()) -> {queue_number(), pid()}.
pick_producer(Producers) ->
    Context = #{},
    pick_producer(Producers, Context).

-spec pick_producer(producers(), produce_context()) -> {queue_number(), pid()}.
pick_producer(Producers = #{workers := Workers, queue_nums := QueueCount, topic := Topic},
              Context = #{}) ->
    Partitioner = maps:get(partitioner, Producers, roundrobin),
    QueueNum = pick_queue_num(Partitioner, QueueCount, Topic, Context),
    do_pick_producer(QueueNum, QueueCount, Workers).

do_pick_producer(QueueNum0, QueueCount, Workers) ->
    Pid0 = lookup_producer(Workers, QueueNum0),
    case is_pid(Pid0) andalso is_process_alive(Pid0) of
        true ->
            {QueueNum0, Pid0};
        false ->
            R = {QueueNum1, _Pid1} = pick_next_alive(Workers, QueueNum0, QueueCount),
            _ = put(rocketmq_roundrobin, (QueueNum1 + 1) rem QueueCount),
            R
    end.

pick_next_alive(Workers, QueueNum, QueueCount) ->
    pick_next_alive(Workers, (QueueNum + 1) rem QueueCount, QueueCount, _Tried = 1).

pick_next_alive(_Workers, _QueueNum, QueueCount, QueueCount) ->
    erlang:error(all_producers_down);
pick_next_alive(Workers, QueueNum, QueueCount, Tried) ->
    case lookup_producer(Workers, QueueNum) of
        {error, _} ->
            pick_next_alive(Workers, (QueueNum + 1) rem QueueCount, QueueCount, Tried + 1);
        Pid ->
            case is_alive(Pid) of
                true -> {QueueNum, Pid};
                false -> pick_next_alive(Workers, (QueueNum + 1) rem QueueCount, QueueCount, Tried + 1)
            end
    end.

is_alive(Pid) -> is_pid(Pid) andalso is_process_alive(Pid).

lookup_producer(#{workers := Workers}, QueueNum) ->
    lookup_producer(Workers, QueueNum);
lookup_producer(Workers, QueueNum) when is_map(Workers) ->
    maps:get(QueueNum, Workers);
lookup_producer(Workers, QueueNum) ->
    case ets:lookup(Workers, QueueNum) of
        [] -> {error, get_worker_fail};
        [{QueueNum, Pid}] -> Pid
    end.

-spec pick_queue_num(partitioner(), queue_count(), topic(), produce_context()) -> queue_number().
pick_queue_num(roundrobin, QueueCount0, Topic, _Context) ->
    QueueCount =  case ets:lookup(rocketmq_topic, Topic) of
        [] -> QueueCount0;
        [{_, QueueCount1}] -> QueueCount1
    end,
    QueueNum = case get(rocketmq_roundrobin) of
        undefined -> 0;
        Number    -> Number
    end,
    _ = put(rocketmq_roundrobin, (QueueNum + 1) rem QueueCount),
    QueueNum;
pick_queue_num(key_dispatch, QueueCount, _Topic, _Context = #{key := Key}) ->
    erlang:phash2(Key, QueueCount).

start_link(ClientId, ProducerGroup, Topic, ProducerOpts) ->
    gen_server:start_link({local, get_name(ProducerOpts)}, ?MODULE, [ClientId, ProducerGroup, Topic, ProducerOpts], []).

init([ClientId, ProducerGroup, Topic, ProducerOpts]) ->
    erlang:process_flag(trap_exit, true),
    RefTopicRouteInterval = maps:get(ref_topic_route_interval, ProducerOpts, 5000),
    erlang:send_after(RefTopicRouteInterval, self(), ref_topic_route),
    State = #state{
        topic = Topic,
        client_id = ClientId,
        producer_opts = ProducerOpts,
        producer_group = ProducerGroup,
        ref_topic_route_interval = RefTopicRouteInterval,
        workers = ensure_ets_created(get_name(ProducerOpts))
    },
    case init_producers(ClientId, State) of
        {ok, State1} -> {ok, State1};
        {error, Reason} -> {stop, {shutdown, Reason}}
    end.

init_producers(ClientId, State) ->
    case rocketmq_client_sup:find_client(ClientId) of
        {ok, Pid} ->
            case maybe_start_producer(Pid, State) of
                {ok, {QueueNums, NewProducers, BrokerDatas}} ->
                    {ok, State#state{
                            queue_nums = QueueNums,
                            producers = NewProducers,
                            broker_datas = BrokerDatas}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

handle_call(get_workers, _From, State = #state{workers = Workers, queue_nums = QueueNum}) ->
    {reply, {QueueNum, Workers}, State};

handle_call(_Call, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, _Error}, State = #state{workers = Workers, producers = Producers, producer_opts = ProducerOpts}) ->
    case maps:get(Pid, Producers, undefined) of
        undefined ->
            log_error("Not find Pid:~p producer", [Pid]),
            {noreply, State};
        {BrokerAddrs, QueueNum} ->
            ets:delete(Workers, QueueNum),
            RestartAfter = maps:get(producer_restart_interval, ProducerOpts, ?RESTART_INTERVAL),
            erlang:send_after(RestartAfter, self(), {start_producer, BrokerAddrs, QueueNum}),
            {noreply, State#state{producers = maps:remove(Pid, Producers)}}
    end;

handle_info({start_producer, BrokerAddrs, QueueSeq}, State = #state{producers = Producers}) ->
    NewProducers = do_start_producer(BrokerAddrs, QueueSeq, Producers, State),
    {noreply, State#state{producers = NewProducers}};

handle_info(ref_topic_route, State = #state{client_id = ClientId,
                                            topic = Topic,
                                            queue_nums = QueueNums,
                                            broker_datas = BrokerDatas,
                                            producers = Producers,
                                            ref_topic_route_interval = RefTopicRouteInterval}) ->
    case rocketmq_client_sup:find_client(ClientId) of
        {ok, Pid} ->
            erlang:send_after(RefTopicRouteInterval, self(), ref_topic_route),
            case rocketmq_client:get_routeinfo_by_topic(Pid, Topic) of
                {ok, {_, undefined}} ->
                    {noreply, State};
                {ok, {_, Payload}} ->
                    BrokerDatas1 = lists:sort(maps:get(<<"brokerDatas">>, Payload, [])),
                    case BrokerDatas1 -- lists:sort(BrokerDatas) of
                        [] -> {noreply, State};
                        BrokerDatas2 ->
                            QueueDatas = maps:get(<<"queueDatas">>, Payload, []),
                            {NewQueueNums, NewProducers} = start_producer(QueueNums, BrokerDatas2, QueueDatas, Producers, State),
                            ets:insert(rocketmq_topic, {Topic, NewQueueNums}),
                            {noreply, State#state{queue_nums = NewQueueNums,
                                                producers = NewProducers,
                                                broker_datas = BrokerDatas1}}
                    end;
                {error, Reason} ->
                    log_error("Get routeinfo by topic failed: ~p", [Reason]),
                    {noreply, State}
                end;
        {error, Reason} ->
            {stop, Reason, State}
    end;

handle_info(_Info, State) ->
    log_error("Receive unknown message:~p~n", [_Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_, _St) -> ok.

get_name(ProducerOpts) -> maps:get(name, ProducerOpts, ?MODULE).

log_error(Fmt, Args) ->
    error_logger:error_msg(Fmt, Args).

maybe_start_producer(Pid, State = #state{topic = Topic, producers = Producers}) ->
    case rocketmq_client:get_routeinfo_by_topic(Pid, Topic) of
        {ok, {_Header, undefined}} ->
            %% Try again using the default topic, as the 'Topic' does not exists for now.
            %% Note that the topic will be created by the rocketmq server automatically
            %% at first time we send message to it, if the user has configured
            %% `autoCreateTopicEnable = true` in the rocketmq server side.
            maybe_start_producer_using_default_topic(Pid, State);
        {ok, {_, RouteInfo}} ->
            start_producer_with_route_info(RouteInfo, Producers, State);
        {error, Reason} ->
            log_error("Get routeinfo by topic failed: ~p, topic: ~p", [Reason, Topic]),
            {error, {get_routeinfo_by_topic_failed, Reason}}
    end.

maybe_start_producer_using_default_topic(Pid, State = #state{producers = Producers}) ->
    case rocketmq_client:get_routeinfo_by_topic(Pid, ?DEFAULT_TOPIC) of
        {ok, {Header, undefined}} ->
            log_error("Start producer failed, remark: ~p",
                [maps:get(<<"remark">>, Header, undefined)]),
            {error, {start_producer_failed, Header}};
        {ok, {_, RouteInfo}} ->
            start_producer_with_route_info(RouteInfo, Producers, State);
        {error, Reason} ->
            log_error("Get routeinfo by topic failed: ~p, topic: ~p", [Reason, ?DEFAULT_TOPIC]),
            {error, {get_routeinfo_by_topic_failed, Reason}}
    end.

find_queue_data(_Key, []) ->
    [];
find_queue_data(Key, [QueueData | QueueDatas]) ->
    BrokerName = maps:get(<<"brokerName">>, QueueData),
    case BrokerName =:= Key of
        true -> QueueData;
        false -> find_queue_data(Key, QueueDatas)
    end.

start_producer_with_route_info(RouteInfo, Producers, State) ->
    BrokerDatas = maps:get(<<"brokerDatas">>, RouteInfo, []),
    QueueDatas = maps:get(<<"queueDatas">>, RouteInfo, []),
    {QueueNums, NewProducers} = start_producer(0, BrokerDatas, QueueDatas, Producers, State),
    {ok, {QueueNums, NewProducers, BrokerDatas}}.

start_producer(Start, BrokerDatas,  QueueDatas, Producers, State = #state{topic = Topic}) ->
    lists:foldl(fun(BrokerData, {QueueNumAcc, ProducersAcc}) ->
        BrokerAddrs = maps:get(<<"brokerAddrs">>, BrokerData),
        BrokerName = maps:get(<<"brokerName">>, BrokerData),
        QueueData = find_queue_data(BrokerName, QueueDatas),
        case maps:get(<<"perm">>, QueueData) =:= 4 of
            true ->
                log_error("Start producer fail; topic: ~p; permission denied", [Topic]),
                {QueueNumAcc, ProducersAcc};
            false ->
                QueueNum = maps:get(<<"writeQueueNums">>, QueueData),
                ProducersAcc1 =
                    lists:foldl(fun(QueueSeq, Acc) ->
                            do_start_producer(BrokerAddrs, QueueSeq, Acc, State)
                        end, ProducersAcc, lists:seq(0, QueueNum - 1)),
                {QueueNumAcc + QueueNum, ProducersAcc1}
        end
    end, {Start, Producers}, BrokerDatas).

do_start_producer(BrokerAddrs, QueueSeq, Producers, #state{workers = Workers,
                                                        topic = Topic,
                                                        producer_group = ProducerGroup,
                                                        producer_opts = ProducerOpts}) ->
    Server = maps:get(<<"0">>, BrokerAddrs),
    {ok, Producer} = rocketmq_producer:start_link(QueueSeq, Topic, Server, ProducerGroup, ProducerOpts),
    ets:insert(Workers, {QueueSeq, Producer}),
    maps:put(Producer, {BrokerAddrs, QueueSeq}, Producers).

ensure_ets_created(TabName) ->
    try ets:new(TabName, [protected, named_table, {read_concurrency, true}])
    catch
        error:badarg -> TabName %% already exists
    end.
