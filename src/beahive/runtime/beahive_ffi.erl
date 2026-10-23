-module(beahive_ffi).
-export([
    app_version/1,
    parse_ip/1
    ]).

app_version(AppAtom) ->
    case application:get_key(AppAtom, vsn) of
        {ok, VersionStr} -> list_to_binary(VersionStr);
        undefined -> <<"0.0.0">>
    end.

%% "2001:DB8::1" -> {ok, {ip_v6, ...}}, the representation of `ewe.IpAddress`.
parse_ip(Text) ->
    case inet:parse_strict_address(string:trim(unicode:characters_to_list(Text))) of
        {ok, {A, B, C, D}} -> {ok, {ip_v4, A, B, C, D}};
        {ok, {A, B, C, D, E, F, G, H}} -> {ok, {ip_v6, A, B, C, D, E, F, G, H}};
        {error, _} -> {error, nil}
    end.