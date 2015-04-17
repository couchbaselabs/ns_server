%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(menelaus_web_indexes).

-export([handle_settings_get/1, handle_settings_post/1, handle_index_status/1]).

-import(menelaus_util,
        [reply/2,
         reply_json/2,
         validate_has_params/1,
         validate_unsupported_params/1,
         validate_integer/2,
         validate_range/4,
         execute_if_validated/3]).

handle_settings_get(Req) ->
    menelaus_web:assert_is_sherlock(),

    Settings = index_settings_manager:get(generalSettings),
    true = (Settings =/= undefined),

    reply_json(Req, {Settings}).

validate_settings_post(Args) ->
    R0 = validate_has_params({Args, [], []}),
    R1 = lists:foldl(
           fun ({Key, Min, Max}, Acc) ->
                   Acc1 = validate_integer(Key, Acc),
                   validate_range(Key, Min, Max, Acc1)
           end, R0, supported_settings()),

    validate_unsupported_params(R1).

handle_settings_post(Req) ->
    menelaus_web:assert_is_sherlock(),

    execute_if_validated(
      fun (Values) ->
              case index_settings_manager:update(generalSettings, Values) of
                  {ok, NewSettingsAll} ->
                      {_, NewSettings} = lists:keyfind(generalSettings, 1, NewSettingsAll),
                      reply_json(Req, {NewSettings});
                  retry_needed ->
                      reply(Req, 409)
              end
      end, Req, validate_settings_post(Req:parse_post())).

supported_settings() ->
    NearInfinity = 1 bsl 64 - 1,
    [{indexerThreads, 1, 1024},
     {memorySnapshotInterval, 1, NearInfinity},
     {stableSnapshotInterval, 1, NearInfinity},
     {maxRollbackPoints, 1, NearInfinity}].

handle_index_status(Req) ->
    Config = ns_config:get(),
    LocalAddr = menelaus_util:local_addr(Req),
    NodeInfos = ns_doctor:get_nodes(),
    Indexes0 =
        lists:flatmap(
          fun (Node) ->
                  NodeInfo = misc:dict_get(Node, NodeInfos, []),
                  Hostname0 = menelaus_web:build_node_hostname(Config, Node, LocalAddr),
                  Hostname = list_to_binary(Hostname0),
                  IndexStatus = proplists:get_value(index_status, NodeInfo, []),
                  NodeIndexes = proplists:get_value(indexes, IndexStatus, []),

                  [{[{hostname, Hostname} | Props]} || Props <- NodeIndexes]
          end, ns_cluster_membership:index_active_nodes()),

    GetSortKey =
        fun ({Index}) ->
                {_, Hostname} = lists:keyfind(hostname, 1, Index),
                {_, Bucket} = lists:keyfind(bucket, 1, Index),
                {_, IndexName} = lists:keyfind(index, 1, Index),

                {Hostname, Bucket, IndexName}
        end,

    Indexes =
        lists:sort(
          fun (A, B) ->
                  GetSortKey(A) =< GetSortKey(B)
          end, Indexes0),

    reply_json(Req, Indexes).