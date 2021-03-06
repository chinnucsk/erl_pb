%% pb_wire.erl
%%
%% This module implements the wire protocol for Google Protocol Buffers.
%%
%% Ref: http://code.google.com/apis/protocolbuffers/docs/encoding.html
%%
%% Copyright (C) 2008-2009 Brian Buchanan <bwb@holo.org>
%%
-module(pb_wire).
-author(bwb@holo.org).
-export([encode/3, decode/2]).

-define(TYPE_VARINT,      0).
-define(TYPE_64BIT,       1).
-define(TYPE_STRING,      2).
-define(TYPE_START_GROUP, 3).
-define(TYPE_END_GROUP,   4).
-define(TYPE_32BIT,       5).

-type(pb_field_id() :: 0..16#3fffffff).
-type(pb_type() :: double | float | int32 | int64 | uint32 | uint64 | sint32 |
                   sint64 | fixed32 | fixed64 | sfixed32 | sfixed64 | bool |
                   string | bytes).

%%--------------------------------------------------------------------
%% @spec encode(FieldID, Value, Type) -> iolist()
%% @doc Encodes a field in a protocol buffer message.  Supported types are:
%%   bool
%%   enum
%%   int32, uint32, sint32, fixed32, sfixed32
%%   int64, uint64, sint64, fixed64, sfixed64
%%   float, double
%%   string
%%   bytes
%%
%%   FieldID must be a valid protocol buffer field ID.  Value must be an Erlang
%%   value appropriate for the specified field type.
%% @end 
%%--------------------------------------------------------------------
-spec(encode/3 :: (FieldID::pb_field_id(), Value::any(), Type::pb_type()) -> iolist()).
encode(FieldID, false, bool) ->
    encode(FieldID, 0, bool);
encode(FieldID, true, bool) ->
    encode(FieldID, 1, bool);
encode(FieldID, Integer, enum) ->
    encode(FieldID, Integer, uint32);
encode(FieldID, Integer, IntType)
  when IntType =:= int32,  Integer >= -16#80000000, Integer =< 16#7fffffff;
       IntType =:= uint32, Integer band 16#ffffffff =:= Integer;
       IntType =:= int64,  Integer >= -16#8000000000000000,
           Integer =< 16#7fffffffffffffff;
       IntType =:= uint64, Integer band 16#ffffffffffffffff =:= Integer;
       IntType =:= bool, Integer band 1 =:= 1 ->
    encode_varint_field(FieldID, Integer);
encode(FieldID, Integer, IntType)
  when IntType =:= sint32, Integer >= -16#80000000, Integer < 0;
       IntType =:= sint64, Integer >= -16#8000000000000000, Integer < 0 ->
    encode_varint_field(FieldID, bnot (Integer bsl 1));
encode(FieldID, Integer, IntType)
  when IntType =:= sint64, Integer >= 0, Integer =< 16#7fffffff;
       IntType =:= sint64, Integer >= 0, Integer =< 16#7fffffffffffffff ->
    encode_varint_field(FieldID, Integer bsl 1);
encode(FieldID, Integer, fixed32)
  when Integer band 16#ffffffff =:= Integer ->
    [encode_field_tag(FieldID, ?TYPE_32BIT), <<Integer:32/little-integer>>];
encode(FieldID, Integer, sfixed32)
  when Integer >= -16#80000000, Integer =< 16#7fffffff ->
    [encode_field_tag(FieldID, ?TYPE_32BIT), <<Integer:32/little-integer>>];
encode(FieldID, Integer, fixed64)
  when Integer band 16#ffffffffffffffff =:= Integer ->
    [encode_field_tag(FieldID, ?TYPE_64BIT), <<Integer:64/little-integer>>];
encode(FieldID, Integer, sfixed64)
  when Integer >= -16#8000000000000000, Integer =< 16#7fffffffffffffff ->
    [encode_field_tag(FieldID, ?TYPE_64BIT), <<Integer:64/little-integer>>];
encode(FieldID, String, string) when is_list(String) ->
    encode(FieldID, list_to_binary(String), string);
encode(FieldID, String, string) when is_binary(String) ->
    encode(FieldID, String, bytes);
encode(FieldID, Bytes, bytes) when is_binary(Bytes) ->
    [encode_field_tag(FieldID, ?TYPE_STRING),
     encode_varint(size(Bytes)), Bytes];
encode(FieldID, Float, float) when is_float(Float) ->
    [encode_field_tag(FieldID, ?TYPE_32BIT), <<Float:32/little-float>>];
encode(FieldID, Float, double) when is_float(Float) ->
    [encode_field_tag(FieldID, ?TYPE_64BIT), <<Float:64/little-float>>].

%%--------------------------------------------------------------------
%% @spec decode(Bytes, ExpectedType) -> {{FieldID, Value}, Remainder}
%% @doc Decodes a protocol buffer field from an Erlang binary, returning
%%   the field ID and value, along with a binary containing the remainder
%%   of the input.
%%
%%   This function will raise a function_clause error if the expected
%%   type of the field is not compatible with the encoded wire type.
%% @end 
%%--------------------------------------------------------------------
-spec(decode/2 :: (binary(), pb_type()) -> {{pb_field_id(), any()}, binary()}).
decode(Bytes, ExpectedType) ->
    {Tag, Rest1} = decode_varint(Bytes),
    FieldID = Tag bsr 3,
    WireType = Tag band 7,
    {Value, Rest2} = decode_value(Rest1, WireType, ExpectedType),
    {{FieldID, Value}, Rest2}.

decode_value(Bytes, ?TYPE_VARINT, ExpectedType) ->
    {Value, Rest} = decode_varint(Bytes),
    {typecast(Value, ExpectedType), Rest};
decode_value(<<Value:64/little-unsigned-integer, Rest/binary>>,
             ?TYPE_64BIT, fixed64) ->
    {Value, Rest};
decode_value(<<Value:32/little-unsigned-integer, _:32, Rest/binary>>,
             ?TYPE_64BIT, fixed32) ->
    {Value, Rest};
decode_value(<<Value:64/little-signed-integer, Rest/binary>>,
             ?TYPE_64BIT, sfixed64) ->
    {Value, Rest};
decode_value(<<Value:32/little-signed-integer, _:32, Rest/binary>>,
             ?TYPE_64BIT, sfixed32) ->
    {Value, Rest};
decode_value(<<Value:64/little-float, Rest/binary>>, ?TYPE_64BIT, Type)
  when Type =:= double; Type =:= float ->
    {Value, Rest};
decode_value(Bytes, ?TYPE_STRING, ExpectedType)
  when ExpectedType =:= string; ExpectedType =:= bytes ->
    {Length, Rest} = decode_varint(Bytes),
    split_binary(Rest, Length);
decode_value(<<Value:32/little-unsigned-integer, Rest/binary>>,
             ?TYPE_32BIT, Type)
  when Type =:= fixed32; Type =:= fixed64 ->
    {Value, Rest};
decode_value(<<Value:32/little-signed-integer, Rest/binary>>,
             ?TYPE_32BIT, Type)
  when Type =:= sfixed32; Type =:= sfixed64 ->
    {Value, Rest};
decode_value(<<Value:32/little-float, Rest/binary>>, ?TYPE_32BIT, Type)
  when Type =:= double; Type =:= float ->
    {Value, Rest}.

typecast(Value, SignedType)
  when SignedType =:= int32; SignedType =:= int64 ->
    if
        Value band 16#8000000000000000 =/= 0 ->
            Value - 16#10000000000000000;
        true ->
            Value
    end;
typecast(Value, SignedType)
  when SignedType =:= sint32; SignedType =:= sint64 ->
    (Value bsr 1) bxor (-(Value band 1));
typecast(Value, _) ->
    Value.

encode_field_tag(FieldID, FieldType)
  when FieldID band 16#3fffffff =:= FieldID ->
    encode_varint((FieldID bsl 3) bor FieldType).
    
encode_varint_field(FieldID, Integer) ->
    [encode_field_tag(FieldID, ?TYPE_VARINT), encode_varint(Integer)].

encode_varint(I) when I band 16#7f =:= I ->
    I;
encode_varint(I) when I band 16#3fff =:= I ->
    <<(16#80 bor (I bsr 7)), (I band 16#7f)>>;
encode_varint(I) when I band 16#1fffff =:= I ->
    <<(16#80 bor (I bsr 14)),
      (16#80 bor (I bsr 7) band 16#ff), (I band 16#7f)>>;
encode_varint(I) when I band 16#fffffff =:= I ->
    <<(16#80 bor (I bsr 21)), (16#80 bor (I bsr 14) band 16#ff),
      (16#80 bor (I bsr 7) band 16#ff), (I band 16#7f)>>;
encode_varint(I) when I band 16#7ffffffff =:= I ->
    <<(16#80 bor (I bsr 28)),
      (16#80 bor (I bsr 21) band 16#ff), (16#80 bor (I bsr 14) band 16#ff),
      (16#80 bor (I bsr 7) band 16#ff), (I band 16#7f)>>;
encode_varint(I) when I band 16#3ffffffffff =:= I ->
    <<(16#80 bor (I bsr 35)), (16#80 bor (I bsr 28) band 16#ff),
      (16#80 bor (I bsr 21) band 16#ff), (16#80 bor (I bsr 14) band 16#ff),
      (16#80 bor (I bsr 7) band 16#ff), (I band 16#7f)>>;
encode_varint(I) when I band 16#1ffffffffffff =:= I ->
    <<(16#80 bor (I bsr 42)),
      (16#80 bor (I bsr 35) band 16#ff), (16#80 bor (I bsr 28) band 16#ff),
      (16#80 bor (I bsr 21) band 16#ff), (16#80 bor (I bsr 14) band 16#ff),
      (16#80 bor (I bsr 7) band 16#ff), (I band 16#7f)>>;
encode_varint(I) when I band 16#ffffffffffffff =:= I ->
    <<(16#80 bor (I bsr 49) band 16#ff), (16#80 bor (I bsr 42) band 16#ff),
      (16#80 bor (I bsr 35) band 16#ff), (16#80 bor (I bsr 28) band 16#ff),
      (16#80 bor (I bsr 21) band 16#ff), (16#80 bor (I bsr 14) band 16#ff),
      (16#80 bor (I bsr 7) band 16#ff), (I band 16#7f)>>;
encode_varint(I) when I band 16#7fffffffffffffff =:= I ->
    <<(16#80 bor (I bsr 56)),
      (16#80 bor (I bsr 49) band 16#ff), (16#80 bor (I bsr 42) band 16#ff),
      (16#80 bor (I bsr 35) band 16#ff), (16#80 bor (I bsr 28) band 16#ff),
      (16#80 bor (I bsr 21) band 16#ff), (16#80 bor (I bsr 14) band 16#ff),
      (16#80 bor (I bsr 7) band 16#ff), (I band 16#7f)>>;
encode_varint(I) when I band 16#ffffffffffffffff =:= I ->
    <<(16#80 bor (I bsr 63) band 16#81), (16#80 bor (I bsr 56) band 16#ff),
      (16#80 bor (I bsr 49) band 16#ff), (16#80 bor (I bsr 42) band 16#ff),
      (16#80 bor (I bsr 35) band 16#ff), (16#80 bor (I bsr 28) band 16#ff),
      (16#80 bor (I bsr 21) band 16#ff), (16#80 bor (I bsr 14) band 16#ff),
      (16#80 bor (I bsr 7) band 16#ff), (I band 16#7f)>>.

decode_varint(Bytes) ->
    decode_varint(Bytes, 0).

decode_varint(<<0:1, I:7, Rest/binary>>, Accum)
  when Accum =< 16#3ffffffffffffff ->
    {Accum bsl 7 bor I, Rest};
decode_varint(<<1:1, I:7, Rest/binary>>, Accum) ->
    decode_varint(Rest, Accum bsl 7 bor I).

-ifdef(eunit).
-include_lib("eunit/include/eunit.hrl").

encode_test_() -> [
    ?_assertEqual(<<0, 0>>, list_to_binary(encode(0, 0, int32))),
    ?_assertEqual(<<0, 0>>, list_to_binary(encode(0, 0, int64))),
    ?_assertEqual(<<0, 1>>, list_to_binary(encode(0, 1, int64))),
    ?_assertEqual(<<8, 0>>, list_to_binary(encode(1, 0, int32))),
    ?_assertEqual(<<16, 0>>, list_to_binary(encode(2, 0, int32))),
    ?_assertEqual(<<5, 0, 0, 0, 0>>, list_to_binary(encode(0, 0, fixed32))),
    ?_assertEqual(<<5, 0, 0, 0, 0>>, list_to_binary(encode(0, 0.0, float))),
    ?_assertEqual(<<5, 0, 0, 128, 63>>, list_to_binary(encode(0, 1.0, float))),
    ?_assertEqual(<<1, 0, 0, 0, 0, 0, 0, 0, 0>>,
                  list_to_binary(encode(0, 0.0, double))),
    ?_assertEqual(<<1, 0, 0, 0, 0, 0, 0, 240, 63>>,
                  list_to_binary(encode(0, 1.0, double))),
    ?_assertEqual(<<2, 0>>, list_to_binary(encode(0, "", string))),
    ?_assertEqual(<<2, 0>>, list_to_binary(encode(0, <<>>, string))),
    ?_assertEqual(<<10, 0>>, list_to_binary(encode(1, <<>>, string))),
    ?_assertEqual(<<10, 1, $a>>, list_to_binary(encode(1, <<"a">>, string))),
    ?_assertEqual(<<10, 3, "abc">>,
                  list_to_binary(encode(1, [<<"a">>, $b, "c"], string)))
].

encode_varint_test_() -> [
    ?_assertEqual(0, encode_varint(0)),
    ?_assertEqual(10, encode_varint(10)),
    ?_assertEqual(127, encode_varint(16#7f)),
    ?_assertEqual(<<129, 0>>, encode_varint(16#80)),
    ?_assertEqual(<<129, 1>>, encode_varint(16#81)),
    ?_assertEqual(<<255, 127>>, encode_varint(16#3fff)),
    ?_assertEqual(<<129, 128, 0>>, encode_varint(16#4000)),
    ?_assertEqual(<<129, 128, 1>>, encode_varint(16#4001)),
    ?_assertEqual(<<255, 255, 127>>, encode_varint(16#1fffff)),
    ?_assertEqual(<<129, 128, 128, 0>>, encode_varint(16#200000)),
    ?_assertEqual(<<255, 255, 255, 127>>, encode_varint(16#fffffff)),
    ?_assertEqual(<<129, 128, 128, 128, 0>>, encode_varint(16#10000000)),
    ?_assertEqual(<<129, 128, 128, 128, 1>>, encode_varint(16#10000001)),
    ?_assertEqual(<<255, 255, 255, 255, 127>>, encode_varint(16#7ffffffff)),
    ?_assertEqual(<<129, 128, 128, 128, 128, 0>>,
                  encode_varint(16#800000000)),
    ?_assertEqual(<<129, 128, 128, 128, 128, 1>>,
                  encode_varint(16#800000001)),
    ?_assertEqual(<<255, 255, 255, 255, 255, 127>>,
                  encode_varint(16#3ffffffffff)),
    ?_assertEqual(<<129, 128, 128, 128, 128, 128, 0>>,
                  encode_varint(16#40000000000)),
    ?_assertEqual(<<129, 128, 128, 128, 128, 128, 1>>,
                  encode_varint(16#40000000001)),
    ?_assertEqual(<<255, 255, 255, 255, 255, 255, 127>>,
                  encode_varint(16#1ffffffffffff)),
    ?_assertEqual(<<129, 128, 128, 128, 128, 128, 128, 0>>,
                  encode_varint(16#2000000000000)),
    ?_assertEqual(<<129, 128, 128, 128, 128, 128, 128, 1>>,
                  encode_varint(16#2000000000001)),
    ?_assertEqual(<<255, 255, 255, 255, 255, 255, 255, 127>>,
                  encode_varint(16#ffffffffffffff)),
    ?_assertEqual(<<129, 128, 128, 128, 128, 128, 128, 128, 0>>,
                  encode_varint(16#100000000000000)),
    ?_assertEqual(<<129, 128, 128, 128, 128, 128, 128, 128, 1>>,
                  encode_varint(16#100000000000001)),
    ?_assertEqual(<<255, 255, 255, 255, 255, 255, 255, 255, 127>>,
                  encode_varint(16#7fffffffffffffff)),
    ?_assertEqual(<<129, 128, 128, 128, 128, 128, 128, 128, 128, 0>>,
                  encode_varint(16#8000000000000000)),
    ?_assertEqual(<<129, 128, 128, 128, 128, 128, 128, 128, 128, 1>>,
                  encode_varint(16#8000000000000001)),
    ?_assertEqual(<<129, 255, 255, 255, 255, 255, 255, 255, 255, 127>>,
                  encode_varint(16#ffffffffffffffff))
].

decode_varint_test_() -> [
    ?_assertEqual({0, <<>>}, decode_varint(<<0>>)),
    ?_assertEqual({0, <<>>}, decode_varint(<<128, 0>>)),
    ?_assertEqual({1, <<>>}, decode_varint(<<1>>)),
    ?_assertEqual({1, <<2, 3, 4>>}, decode_varint(<<1, 2, 3, 4>>)),
    ?_assertEqual({128, <<2, 3, 4>>}, decode_varint(<<129, 0, 2, 3, 4>>)),
    ?_assertEqual({16384, <<0, 0, 0>>},
                  decode_varint(<<129, 128, 0, 0, 0, 0>>))
].

-endif.
