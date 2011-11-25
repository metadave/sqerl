%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Mark Anderson <mark@opscode.com>
%% @copyright Copyright 2011 Opscode, Inc.
%% @end
%% @doc Abstraction around interacting with pgsql databases
-module(sqerl_pgsql_client).

-behaviour(sqerl_client).

-include_lib("epgsql/include/pgsql.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/1]).

%% sqerl_client callbacks
-export([init/1,
         exec_prepared_statement/3,
         exec_prepared_select/3]).

-record(state, {cn,
                statements = dict:new() :: dict(),
                ctrans :: dict() | undefined }).

-type connection() :: pid().
-type state() :: any().

start_link(Config) ->
    sqerl_client:start_link(?MODULE, Config).

-spec exec_prepared_select(atom(), [], state()) -> {{ok, [[tuple()]]} | {error, any()}, state()}.
exec_prepared_select(Name, Args, #state{cn=Cn, statements=Statements, ctrans=CTrans}=State) ->
    {Columns, Stmt} = dict:fetch(Name, Statements),
    NArgs = input_transforms(Args,State),
    ok = pgsql:bind(Cn, Stmt, NArgs),
    %% Note: we might get partial results here for big selects!
    Result = pgsql:execute(Cn, Stmt),
    case Result of
        {ok, RowData} ->
            Rows = unpack_rows(Columns, RowData),
            TRows = sqerl_transformers:by_column_name(Rows, CTrans),
            {{ok, TRows}, State};
        Result ->
            {{error, Result}, State}
    end.

-spec exec_prepared_statement(atom(), [], any()) -> {{ok, integer()} | {error, any()}, state()}.
exec_prepared_statement(Name, Args, #state{cn=Cn, statements=Statements}=State) ->
    {_Columns, Stmt} = dict:fetch(Name, Statements),
    NArgs = input_transforms(Args, State),
    ok = pgsql:bind(Cn, Stmt, NArgs),
    %% Note: we might get partial results here for big selects!
    Rv =
        try 
            case pgsql:execute(Cn, Stmt) of
                {ok, Count} -> 
                    {{ok, Count}, State};
                Result ->
                    {{error, Result}, State}
            end
        catch 
            _:X -> ?debugVal(X), ?debugVal(erlang:get_stacktrace())
        end,
    pgsql:squery(Cn, "COMMIT"),
    Rv.

init(Config) ->
    {host, Host} = lists:keyfind(host, 1, Config),
    {port, Port} = lists:keyfind(port, 1, Config),
    {user, User} = lists:keyfind(user, 1, Config),
    {pass, Pass} = lists:keyfind(pass, 1, Config),
    {db, Db} = lists:keyfind(db, 1, Config),
    {prepared_statement_source, PreparedStatementFile} = lists:keyfind(prepared_statement_source, 1, Config),
    Opts = [{database, Db}, {port, Port}],
    CTrans = 
        case lists:keyfind(column_transforms, 1, Config) of
            {column_transforms, CT} -> CT;
            false -> undefined
        end,
    case pgsql:connect(Host, User, Pass, Opts) of
        {error, timeout} ->
            {stop, timeout};
        {ok, Connection} ->
            %% Link to pid so if this process dies we clean up
            %% the socket
            erlang:link(Connection),
            erlang:process_flag(trap_exit, true),
            {ok, Statements} = file:consult(PreparedStatementFile),
            {ok, Prepared} = load_statements(Connection, Statements, dict:new()),
            {ok, #state{cn=Connection, statements=Prepared, ctrans=CTrans}};
        {error, {syntax, Msg}} ->
            {stop, {syntax, Msg}};
        X -> ?debugVal(X),                
             {stop, X}
    end.

%% Internal functions
-spec load_statements(connection(), [tuple()], dict()) -> {ok, dict()} |  {error, any()}.
load_statements(_Connection, [], Dict) ->
    {ok, Dict};
load_statements(Connection, [{Name, SQL}|T], Dict) when is_atom(Name) ->
    case pgsql:parse(Connection, atom_to_list(Name), SQL, []) of
        {ok, Statement} ->
            {ok, {statement, _Name, Desc, _DataTypes}} = pgsql:describe(Connection, Statement),
            Columns = [ ColName || {_,ColName, _, _, _,_} <- Desc],
            load_statements(Connection, T, dict:store(Name, {Columns, Statement}, Dict));
        {error, {error, error, _ErrorCode, Msg, Position}} ->
            {error, {syntax, {Msg, Position}}};
        Error ->
            %% TODO: Discover what errors can flow out of this, and write tests.
            ?debugVal(Error),
            {error, Error}
    end.

%% Converts contents of result_packet into our "standard"
%% representation of a list of proplists. In other words,
%% each row is converted into a proplist and then collected
%% up into a list containing all the converted rows for
%% a given query result.

-spec unpack_rows([binary()], [[any()]]) -> [[{any(), any()}]].
unpack_rows(Columns, RowData) ->
    [ lists:zip(Columns, tuple_to_list(Row)) || Row <- RowData ].

transform({datetime, X}) ->
    X;
transform(X) ->
    X.

input_transforms(Data, _State) ->
    [ transform(E) || E <- Data ].
