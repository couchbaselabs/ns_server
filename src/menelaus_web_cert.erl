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
%% @doc REST api's for handling ssl certificates

-module(menelaus_web_cert).

-include("ns_common.hrl").

-export([handle_cluster_certificate/1,
         handle_regenerate_certificate/1,
         handle_upload_cluster_ca/1,
         handle_reload_node_certificate/1]).

handle_cluster_certificate(Req) ->
    menelaus_web:assert_is_enterprise(),

    case proplists:get_value("extended", Req:parse_qs()) of
        "true" ->
            handle_cluster_certificate_extended(Req);
        _ ->
            handle_cluster_certificate_simple(Req)
    end.

handle_cluster_certificate_simple(Req) ->
    Cert = case ns_server_cert:cluster_ca() of
               {GeneratedCert, _} ->
                   GeneratedCert;
               {UploadedCAProps, _, _} ->
                   proplists:get_value(pem, UploadedCAProps)
           end,
    menelaus_util:reply_ok(Req, "text/plain", Cert).

format_time(UTCSeconds) ->
    LocalTime = calendar:universal_time_to_local_time(
                  calendar:gregorian_seconds_to_datetime(UTCSeconds)),
    menelaus_util:format_server_time(LocalTime, 0).

warning_props({expires_soon, UTCSeconds}) ->
    [{message, ns_error_messages:node_certificate_warning(expires_soon)},
     {expires, format_time(UTCSeconds)}];
warning_props(Warning) ->
    [{message, ns_error_messages:node_certificate_warning(Warning)}].

translate_warning({Node, Warning}) ->
    [{node, Node} | warning_props(Warning)].

handle_cluster_certificate_extended(Req) ->
    {Cert, WarningsJson} =
        case ns_server_cert:cluster_ca() of
            {GeneratedCert, _} ->
                {[{type, generated},
                  {pem, GeneratedCert}], []};
            {UploadedCAProps, _, _} ->
                Warnings = ns_server_cert:get_warnings(UploadedCAProps),
                {[{type, uploaded} | UploadedCAProps],
                 [{translate_warning(Pair)} || Pair <- Warnings]}
          end,
    CertJson = lists:map(fun ({K, V}) when is_list(V) ->
                                 {K, list_to_binary(V)};
                             (Pair) ->
                                 Pair
                         end, Cert),
    menelaus_util:reply_json(Req, {[{cert, {CertJson}},
                                    {warnings, WarningsJson}]}).

handle_regenerate_certificate(Req) ->
    menelaus_web:assert_is_enterprise(),

    ns_server_cert:generate_and_set_cert_and_pkey(),
    ns_ssl_services_setup:sync_local_cert_and_pkey_change(),
    ?log_info("Completed certificate regeneration"),
    ns_audit:regenerate_certificate(Req),
    handle_cluster_certificate_simple(Req).

reply_error(Req, Error) ->
    menelaus_util:reply_json(
      Req, {[{error, ns_error_messages:cert_validation_error_message(Error)}]}, 400).

handle_upload_cluster_ca(Req) ->
    menelaus_web:assert_is_enterprise(),
    menelaus_web:assert_is_watson(),

    case Req:recv_body() of
        undefined ->
            reply_error(Req, empty_cert);
        PemEncodedCA ->
            case ns_server_cert:set_cluster_ca(PemEncodedCA) of
                {ok, Props} ->
                    ns_audit:upload_cluster_ca(Req,
                                               proplists:get_value(subject, Props),
                                               proplists:get_value(expires, Props)),
                    handle_cluster_certificate_extended(Req);
                {error, Error} ->
                    reply_error(Req, Error)
            end
    end.

handle_reload_node_certificate(Req) ->
    menelaus_web:assert_is_enterprise(),
    menelaus_web:assert_is_watson(),

    case ns_server_cert:apply_certificate_chain_from_inbox() of
        {ok, Props} ->
            ns_audit:reload_node_certificate(Req,
                                             proplists:get_value(subject, Props),
                                             proplists:get_value(expires, Props)),
            menelaus_util:reply(Req, 200);
        {error, Error} ->
            menelaus_util:reply_json(
              Req, ns_error_messages:reload_node_certificate_error(Error), 400)
    end.
