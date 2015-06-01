%% @author Couchbase, Inc <info@couchbase.com>
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
-module(goxdcr_stats_collector).

-include("ns_common.hrl").

-include("ns_stats.hrl").

%% API
-export([start_link/1]).

%% callbacks
-export([init/1, grab_stats/1, process_stats/5]).

start_link(Bucket) ->
    base_stats_collector:start_link(?MODULE, Bucket).

init(Bucket) ->
    {ok, Bucket}.

grab_stats(Bucket) ->
    case cluster_compat_mode:is_goxdcr_enabled() of
        true ->
            goxdcr_rest:stats(Bucket);
        false ->
            []
    end.

process_stats_loop([], Acc, TotalChangesLeft, TotalDocsRepQueue) ->
    {Acc, TotalChangesLeft, TotalDocsRepQueue};
process_stats_loop([In | T], Reps, TotalChangesLeft, TotalDocsRepQueue) ->
    {RepID, RepStats} = In,
    PerRepStats = [{iolist_to_binary([<<"replications/">>, RepID, <<"/">>, StatK]),
                    StatV} || {StatK, StatV} <- RepStats, is_number(StatV)],
    NewTotalChangesLeft = TotalChangesLeft + proplists:get_value(<<"changes_left">>, RepStats, 0),
    NewTotalDocsRepQueue = TotalDocsRepQueue + proplists:get_value(<<"docs_rep_queue">>, RepStats, 0),
    process_stats_loop(T, [PerRepStats | Reps], NewTotalChangesLeft, NewTotalDocsRepQueue).

process_stats(_TS, Stats, _PrevCounters, _PrevTS, Bucket) ->
    {RepStats, TotalChangesLeft, TotalDocsRepQueue} = process_stats_loop(Stats, [], 0, 0),

    GlobalList = [{<<"replication_changes_left">>, TotalChangesLeft},
                  {<<"replication_docs_rep_queue">>, TotalDocsRepQueue}],

    {[{"@xdcr-" ++ Bucket, lists:sort(lists:append([GlobalList | RepStats]))}],
     undefined, Bucket}.