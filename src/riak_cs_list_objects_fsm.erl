%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

%% @doc

-module(riak_cs_list_objects_fsm).

-behaviour(gen_fsm).

-include("riak_cs.hrl").
-include("list_objects.hrl").

%% API
-export([]).

%% gen_fsm callbacks
-export([init/1,
         prepare/2,
         waiting_list_keys/2,
         waiting_map_reduce/2,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).


-record(state, {riakc_pid :: pid(),
                req :: list_object_request(),
                list_keys_req_id :: undefined | non_neg_integer(),
                key_buffer=[] :: list(),
                keys=[] :: list(),
                objects=[] :: list()}).

%%%===================================================================
%%% API
%%%===================================================================


%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

init([RiakcPid, Request]) ->
    State = #state{riakc_pid=RiakcPid,
                   req=Request},
    {ok, prepare, State, 0}.

prepare(timeout, State=#state{riakc_pid=RiakcPid,
                              req=Request}) ->
    handle_streaming_list_keys_call(make_list_keys_request(RiakcPid, Request),
                                   State).

waiting_list_keys({ReqID, done}, State=#state{list_keys_req_id=ReqID}) ->
    NewState = handle_keys_done(State),
    {next_state, waiting_map_reduce, NewState};
waiting_list_keys({ReqID, {keys, Keys}}, State=#state{list_keys_req_id=ReqID}) ->
    NewState = handle_keys_received(Keys, State),
    {next_state, waiting_list_keys, NewState};
waiting_list_keys({ReqID, {error, Reason}}, State=#state{list_keys_req_id=ReqID}) ->
    %% if we get an error while we're in this state,
    %% we still have the option to return `HTTP 500'
    %% to the client, since we haven't written
    %% any bytes yet
    {stop, Reason, State}.

waiting_map_reduce(_Event, State) ->
    %% depending on whether we have enough results yet
    %% (some of the manifests we requested may be
    %% marked as delete) we will either have to
    %% make another map-reduce request.


    _ = {next_state, waiting_map_reduce, State},
    %% reply the results if we do end up being done
    {stop, normal, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%% the responses from `riakc_pb_socket:stream_list_keys'
%% come back as regular messages, so just pass
%% them along as if they were gen_server events.
handle_info(Info, waiting_list_keys, State) ->
    waiting_list_keys(Info, State);
handle_info(_Info, _StateName, State) ->
    {stop, unknown, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%% Internal helpers
%%--------------------------------------------------------------------

%% function to create a list keys request
%% this could also be a phase-less map-reduce request
%% with key filters.
make_list_keys_request(RiakcPid, ?LOREQ{name=BucketName}) ->
    %% hardcoded for now
    ServerTimeout = timer:seconds(60),
    ManifestBucket = riak_cs_utils:to_bucket_name(objects, BucketName),
    riakc_pb_socket:stream_list_keys(RiakcPid,
                                     ManifestBucket,
                                     ServerTimeout,
                                     infinity).

handle_streaming_list_keys_call({ok, ReqID}, State) ->
    {next_state, waiting_list_keys, State#state{list_keys_req_id=ReqID}};
handle_streaming_list_keys_call({error, Reason}, State) ->
    {stop, Reason, State}.

handle_keys_done(State=#state{key_buffer=ListofListofKeys,
                              req=?LOREQ{name=BucketName},
                              riakc_pid=RiakcPid}) ->
    NewState = State#state{keys=lists:sort(lists:flatten(ListofListofKeys)),
                           %% free up the space
                           key_buffer=undefined},
    ManifestBucketName = riak_cs_utils:to_bucket_name(objects, BucketName),
    handle_map_reduce_call(map_reduce_results(RiakcPid,
                                              ManifestBucketName,
                                              NewState),
                           State).

handle_keys_received(Keys, State=#state{key_buffer=PrevKeyBuffer}) ->
    %% this is where we might eventually do a 'top-k' keys
    %% kind of thing, like
    %% `lists:sublist(lists:sort([Keys | PrevKeyBuffer]), BufferSize)'
    State#state{key_buffer=[Keys | PrevKeyBuffer]}.

map_reduce_results(RiakcPid, ManifestBucketName, Keys) ->
    BKeyTuples = make_bkeys(ManifestBucketName, Keys),
    make_map_reduce_query(RiakcPid, BKeyTuples).

make_bkeys(ManifestBucketName, Keys) ->
    [{ManifestBucketName, Key} || Key <- Keys].

make_map_reduce_query(RiakcPid, BKeyTuples) ->
    %% TODO: change this:
    %% hardcode 60 seconds for now
    Timeout = timer:seconds(60),
    riakc_pb_socket:mapred(RiakcPid,
                           BKeyTuples,
                           mapred_query(),
                           Timeout,
                           infinity).

mapred_query() ->
    [{map, {modfun, riak_cs_utils, map_keys_and_manifests},
      undefined, false},
     {reduce, {modfun, riak_cs_utils, reduce_keys_and_manifests},
      undefined, true}].

handle_map_reduce_call({ok, Results}, _State) -> ok.
