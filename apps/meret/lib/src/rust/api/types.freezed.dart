// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'types.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ItemDto {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ItemDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'ItemDto()';
}


}

/// @nodoc
class $ItemDtoCopyWith<$Res>  {
$ItemDtoCopyWith(ItemDto _, $Res Function(ItemDto) __);
}


/// Adds pattern-matching-related methods to [ItemDto].
extension ItemDtoPatterns on ItemDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( ItemDto_Group value)?  group,TResult Function( ItemDto_Track value)?  track,required TResult orElse(),}){
final _that = this;
switch (_that) {
case ItemDto_Group() when group != null:
return group(_that);case ItemDto_Track() when track != null:
return track(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( ItemDto_Group value)  group,required TResult Function( ItemDto_Track value)  track,}){
final _that = this;
switch (_that) {
case ItemDto_Group():
return group(_that);case ItemDto_Track():
return track(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( ItemDto_Group value)?  group,TResult? Function( ItemDto_Track value)?  track,}){
final _that = this;
switch (_that) {
case ItemDto_Group() when group != null:
return group(_that);case ItemDto_Track() when track != null:
return track(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( GroupDto field0)?  group,TResult Function( int ordinal,  TrackRowDto row)?  track,required TResult orElse(),}) {final _that = this;
switch (_that) {
case ItemDto_Group() when group != null:
return group(_that.field0);case ItemDto_Track() when track != null:
return track(_that.ordinal,_that.row);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( GroupDto field0)  group,required TResult Function( int ordinal,  TrackRowDto row)  track,}) {final _that = this;
switch (_that) {
case ItemDto_Group():
return group(_that.field0);case ItemDto_Track():
return track(_that.ordinal,_that.row);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( GroupDto field0)?  group,TResult? Function( int ordinal,  TrackRowDto row)?  track,}) {final _that = this;
switch (_that) {
case ItemDto_Group() when group != null:
return group(_that.field0);case ItemDto_Track() when track != null:
return track(_that.ordinal,_that.row);case _:
  return null;

}
}

}

/// @nodoc


class ItemDto_Group extends ItemDto {
  const ItemDto_Group(this.field0): super._();
  

 final  GroupDto field0;

/// Create a copy of ItemDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ItemDto_GroupCopyWith<ItemDto_Group> get copyWith => _$ItemDto_GroupCopyWithImpl<ItemDto_Group>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ItemDto_Group&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'ItemDto.group(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $ItemDto_GroupCopyWith<$Res> implements $ItemDtoCopyWith<$Res> {
  factory $ItemDto_GroupCopyWith(ItemDto_Group value, $Res Function(ItemDto_Group) _then) = _$ItemDto_GroupCopyWithImpl;
@useResult
$Res call({
 GroupDto field0
});




}
/// @nodoc
class _$ItemDto_GroupCopyWithImpl<$Res>
    implements $ItemDto_GroupCopyWith<$Res> {
  _$ItemDto_GroupCopyWithImpl(this._self, this._then);

  final ItemDto_Group _self;
  final $Res Function(ItemDto_Group) _then;

/// Create a copy of ItemDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(ItemDto_Group(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as GroupDto,
  ));
}


}

/// @nodoc


class ItemDto_Track extends ItemDto {
  const ItemDto_Track({required this.ordinal, required this.row}): super._();
  

 final  int ordinal;
 final  TrackRowDto row;

/// Create a copy of ItemDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ItemDto_TrackCopyWith<ItemDto_Track> get copyWith => _$ItemDto_TrackCopyWithImpl<ItemDto_Track>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is ItemDto_Track&&(identical(other.ordinal, ordinal) || other.ordinal == ordinal)&&(identical(other.row, row) || other.row == row));
}


@override
int get hashCode {
    return Object.hash(runtimeType,ordinal,row);
}

@override
String toString() {
    return 'ItemDto.track(ordinal: $ordinal, row: $row)';
}


}

/// @nodoc
abstract mixin class $ItemDto_TrackCopyWith<$Res> implements $ItemDtoCopyWith<$Res> {
  factory $ItemDto_TrackCopyWith(ItemDto_Track value, $Res Function(ItemDto_Track) _then) = _$ItemDto_TrackCopyWithImpl;
@useResult
$Res call({
 int ordinal, TrackRowDto row
});




}
/// @nodoc
class _$ItemDto_TrackCopyWithImpl<$Res>
    implements $ItemDto_TrackCopyWith<$Res> {
  _$ItemDto_TrackCopyWithImpl(this._self, this._then);

  final ItemDto_Track _self;
  final $Res Function(ItemDto_Track) _then;

/// Create a copy of ItemDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? ordinal = null,Object? row = null,}) {
  return _then(ItemDto_Track(
ordinal: null == ordinal ? _self.ordinal : ordinal // ignore: cast_nullable_to_non_nullable
as int,row: null == row ? _self.row : row // ignore: cast_nullable_to_non_nullable
as TrackRowDto,
  ));
}


}

/// @nodoc
mixin _$TargetDto {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TargetDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TargetDto()';
}


}

/// @nodoc
class $TargetDtoCopyWith<$Res>  {
$TargetDtoCopyWith(TargetDto _, $Res Function(TargetDto) __);
}


/// Adds pattern-matching-related methods to [TargetDto].
extension TargetDtoPatterns on TargetDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( TargetDto_Search value)?  search,TResult Function( TargetDto_Release value)?  release,TResult Function( TargetDto_Person value)?  person,required TResult orElse(),}){
final _that = this;
switch (_that) {
case TargetDto_Search() when search != null:
return search(_that);case TargetDto_Release() when release != null:
return release(_that);case TargetDto_Person() when person != null:
return person(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( TargetDto_Search value)  search,required TResult Function( TargetDto_Release value)  release,required TResult Function( TargetDto_Person value)  person,}){
final _that = this;
switch (_that) {
case TargetDto_Search():
return search(_that);case TargetDto_Release():
return release(_that);case TargetDto_Person():
return person(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( TargetDto_Search value)?  search,TResult? Function( TargetDto_Release value)?  release,TResult? Function( TargetDto_Person value)?  person,}){
final _that = this;
switch (_that) {
case TargetDto_Search() when search != null:
return search(_that);case TargetDto_Release() when release != null:
return release(_that);case TargetDto_Person() when person != null:
return person(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String query)?  search,TResult Function( PlatformInt64 id)?  release,TResult Function( PlatformInt64 id)?  person,required TResult orElse(),}) {final _that = this;
switch (_that) {
case TargetDto_Search() when search != null:
return search(_that.query);case TargetDto_Release() when release != null:
return release(_that.id);case TargetDto_Person() when person != null:
return person(_that.id);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String query)  search,required TResult Function( PlatformInt64 id)  release,required TResult Function( PlatformInt64 id)  person,}) {final _that = this;
switch (_that) {
case TargetDto_Search():
return search(_that.query);case TargetDto_Release():
return release(_that.id);case TargetDto_Person():
return person(_that.id);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String query)?  search,TResult? Function( PlatformInt64 id)?  release,TResult? Function( PlatformInt64 id)?  person,}) {final _that = this;
switch (_that) {
case TargetDto_Search() when search != null:
return search(_that.query);case TargetDto_Release() when release != null:
return release(_that.id);case TargetDto_Person() when person != null:
return person(_that.id);case _:
  return null;

}
}

}

/// @nodoc


class TargetDto_Search extends TargetDto {
  const TargetDto_Search({required this.query}): super._();
  

 final  String query;

/// Create a copy of TargetDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TargetDto_SearchCopyWith<TargetDto_Search> get copyWith => _$TargetDto_SearchCopyWithImpl<TargetDto_Search>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TargetDto_Search&&(identical(other.query, query) || other.query == query));
}


@override
int get hashCode {
    return Object.hash(runtimeType,query);
}

@override
String toString() {
    return 'TargetDto.search(query: $query)';
}


}

/// @nodoc
abstract mixin class $TargetDto_SearchCopyWith<$Res> implements $TargetDtoCopyWith<$Res> {
  factory $TargetDto_SearchCopyWith(TargetDto_Search value, $Res Function(TargetDto_Search) _then) = _$TargetDto_SearchCopyWithImpl;
@useResult
$Res call({
 String query
});




}
/// @nodoc
class _$TargetDto_SearchCopyWithImpl<$Res>
    implements $TargetDto_SearchCopyWith<$Res> {
  _$TargetDto_SearchCopyWithImpl(this._self, this._then);

  final TargetDto_Search _self;
  final $Res Function(TargetDto_Search) _then;

/// Create a copy of TargetDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? query = null,}) {
  return _then(TargetDto_Search(
query: null == query ? _self.query : query // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class TargetDto_Release extends TargetDto {
  const TargetDto_Release({required this.id}): super._();
  

 final  PlatformInt64 id;

/// Create a copy of TargetDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TargetDto_ReleaseCopyWith<TargetDto_Release> get copyWith => _$TargetDto_ReleaseCopyWithImpl<TargetDto_Release>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TargetDto_Release&&(identical(other.id, id) || other.id == id));
}


@override
int get hashCode {
    return Object.hash(runtimeType,id);
}

@override
String toString() {
    return 'TargetDto.release(id: $id)';
}


}

/// @nodoc
abstract mixin class $TargetDto_ReleaseCopyWith<$Res> implements $TargetDtoCopyWith<$Res> {
  factory $TargetDto_ReleaseCopyWith(TargetDto_Release value, $Res Function(TargetDto_Release) _then) = _$TargetDto_ReleaseCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 id
});




}
/// @nodoc
class _$TargetDto_ReleaseCopyWithImpl<$Res>
    implements $TargetDto_ReleaseCopyWith<$Res> {
  _$TargetDto_ReleaseCopyWithImpl(this._self, this._then);

  final TargetDto_Release _self;
  final $Res Function(TargetDto_Release) _then;

/// Create a copy of TargetDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,}) {
  return _then(TargetDto_Release(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc


class TargetDto_Person extends TargetDto {
  const TargetDto_Person({required this.id}): super._();
  

 final  PlatformInt64 id;

/// Create a copy of TargetDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TargetDto_PersonCopyWith<TargetDto_Person> get copyWith => _$TargetDto_PersonCopyWithImpl<TargetDto_Person>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TargetDto_Person&&(identical(other.id, id) || other.id == id));
}


@override
int get hashCode {
    return Object.hash(runtimeType,id);
}

@override
String toString() {
    return 'TargetDto.person(id: $id)';
}


}

/// @nodoc
abstract mixin class $TargetDto_PersonCopyWith<$Res> implements $TargetDtoCopyWith<$Res> {
  factory $TargetDto_PersonCopyWith(TargetDto_Person value, $Res Function(TargetDto_Person) _then) = _$TargetDto_PersonCopyWithImpl;
@useResult
$Res call({
 PlatformInt64 id
});




}
/// @nodoc
class _$TargetDto_PersonCopyWithImpl<$Res>
    implements $TargetDto_PersonCopyWith<$Res> {
  _$TargetDto_PersonCopyWithImpl(this._self, this._then);

  final TargetDto_Person _self;
  final $Res Function(TargetDto_Person) _then;

/// Create a copy of TargetDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? id = null,}) {
  return _then(TargetDto_Person(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as PlatformInt64,
  ));
}


}

/// @nodoc
mixin _$TransportDto {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TransportDto);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TransportDto()';
}


}

/// @nodoc
class $TransportDtoCopyWith<$Res>  {
$TransportDtoCopyWith(TransportDto _, $Res Function(TransportDto) __);
}


/// Adds pattern-matching-related methods to [TransportDto].
extension TransportDtoPatterns on TransportDto {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( TransportDto_PlayFile value)?  playFile,TResult Function( TransportDto_Pause value)?  pause,TResult Function( TransportDto_Resume value)?  resume,TResult Function( TransportDto_Seek value)?  seek,TResult Function( TransportDto_Next value)?  next,TResult Function( TransportDto_Previous value)?  previous,TResult Function( TransportDto_Stop value)?  stop,TResult Function( TransportDto_FromStart value)?  fromStart,required TResult orElse(),}){
final _that = this;
switch (_that) {
case TransportDto_PlayFile() when playFile != null:
return playFile(_that);case TransportDto_Pause() when pause != null:
return pause(_that);case TransportDto_Resume() when resume != null:
return resume(_that);case TransportDto_Seek() when seek != null:
return seek(_that);case TransportDto_Next() when next != null:
return next(_that);case TransportDto_Previous() when previous != null:
return previous(_that);case TransportDto_Stop() when stop != null:
return stop(_that);case TransportDto_FromStart() when fromStart != null:
return fromStart(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( TransportDto_PlayFile value)  playFile,required TResult Function( TransportDto_Pause value)  pause,required TResult Function( TransportDto_Resume value)  resume,required TResult Function( TransportDto_Seek value)  seek,required TResult Function( TransportDto_Next value)  next,required TResult Function( TransportDto_Previous value)  previous,required TResult Function( TransportDto_Stop value)  stop,required TResult Function( TransportDto_FromStart value)  fromStart,}){
final _that = this;
switch (_that) {
case TransportDto_PlayFile():
return playFile(_that);case TransportDto_Pause():
return pause(_that);case TransportDto_Resume():
return resume(_that);case TransportDto_Seek():
return seek(_that);case TransportDto_Next():
return next(_that);case TransportDto_Previous():
return previous(_that);case TransportDto_Stop():
return stop(_that);case TransportDto_FromStart():
return fromStart(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( TransportDto_PlayFile value)?  playFile,TResult? Function( TransportDto_Pause value)?  pause,TResult? Function( TransportDto_Resume value)?  resume,TResult? Function( TransportDto_Seek value)?  seek,TResult? Function( TransportDto_Next value)?  next,TResult? Function( TransportDto_Previous value)?  previous,TResult? Function( TransportDto_Stop value)?  stop,TResult? Function( TransportDto_FromStart value)?  fromStart,}){
final _that = this;
switch (_that) {
case TransportDto_PlayFile() when playFile != null:
return playFile(_that);case TransportDto_Pause() when pause != null:
return pause(_that);case TransportDto_Resume() when resume != null:
return resume(_that);case TransportDto_Seek() when seek != null:
return seek(_that);case TransportDto_Next() when next != null:
return next(_that);case TransportDto_Previous() when previous != null:
return previous(_that);case TransportDto_Stop() when stop != null:
return stop(_that);case TransportDto_FromStart() when fromStart != null:
return fromStart(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String path)?  playFile,TResult Function()?  pause,TResult Function()?  resume,TResult Function( BigInt ms)?  seek,TResult Function()?  next,TResult Function()?  previous,TResult Function()?  stop,TResult Function()?  fromStart,required TResult orElse(),}) {final _that = this;
switch (_that) {
case TransportDto_PlayFile() when playFile != null:
return playFile(_that.path);case TransportDto_Pause() when pause != null:
return pause();case TransportDto_Resume() when resume != null:
return resume();case TransportDto_Seek() when seek != null:
return seek(_that.ms);case TransportDto_Next() when next != null:
return next();case TransportDto_Previous() when previous != null:
return previous();case TransportDto_Stop() when stop != null:
return stop();case TransportDto_FromStart() when fromStart != null:
return fromStart();case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String path)  playFile,required TResult Function()  pause,required TResult Function()  resume,required TResult Function( BigInt ms)  seek,required TResult Function()  next,required TResult Function()  previous,required TResult Function()  stop,required TResult Function()  fromStart,}) {final _that = this;
switch (_that) {
case TransportDto_PlayFile():
return playFile(_that.path);case TransportDto_Pause():
return pause();case TransportDto_Resume():
return resume();case TransportDto_Seek():
return seek(_that.ms);case TransportDto_Next():
return next();case TransportDto_Previous():
return previous();case TransportDto_Stop():
return stop();case TransportDto_FromStart():
return fromStart();}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String path)?  playFile,TResult? Function()?  pause,TResult? Function()?  resume,TResult? Function( BigInt ms)?  seek,TResult? Function()?  next,TResult? Function()?  previous,TResult? Function()?  stop,TResult? Function()?  fromStart,}) {final _that = this;
switch (_that) {
case TransportDto_PlayFile() when playFile != null:
return playFile(_that.path);case TransportDto_Pause() when pause != null:
return pause();case TransportDto_Resume() when resume != null:
return resume();case TransportDto_Seek() when seek != null:
return seek(_that.ms);case TransportDto_Next() when next != null:
return next();case TransportDto_Previous() when previous != null:
return previous();case TransportDto_Stop() when stop != null:
return stop();case TransportDto_FromStart() when fromStart != null:
return fromStart();case _:
  return null;

}
}

}

/// @nodoc


class TransportDto_PlayFile extends TransportDto {
  const TransportDto_PlayFile({required this.path}): super._();
  

 final  String path;

/// Create a copy of TransportDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TransportDto_PlayFileCopyWith<TransportDto_PlayFile> get copyWith => _$TransportDto_PlayFileCopyWithImpl<TransportDto_PlayFile>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TransportDto_PlayFile&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode {
    return Object.hash(runtimeType,path);
}

@override
String toString() {
    return 'TransportDto.playFile(path: $path)';
}


}

/// @nodoc
abstract mixin class $TransportDto_PlayFileCopyWith<$Res> implements $TransportDtoCopyWith<$Res> {
  factory $TransportDto_PlayFileCopyWith(TransportDto_PlayFile value, $Res Function(TransportDto_PlayFile) _then) = _$TransportDto_PlayFileCopyWithImpl;
@useResult
$Res call({
 String path
});




}
/// @nodoc
class _$TransportDto_PlayFileCopyWithImpl<$Res>
    implements $TransportDto_PlayFileCopyWith<$Res> {
  _$TransportDto_PlayFileCopyWithImpl(this._self, this._then);

  final TransportDto_PlayFile _self;
  final $Res Function(TransportDto_PlayFile) _then;

/// Create a copy of TransportDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? path = null,}) {
  return _then(TransportDto_PlayFile(
path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class TransportDto_Pause extends TransportDto {
  const TransportDto_Pause(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TransportDto_Pause);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TransportDto.pause()';
}


}




/// @nodoc


class TransportDto_Resume extends TransportDto {
  const TransportDto_Resume(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TransportDto_Resume);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TransportDto.resume()';
}


}




/// @nodoc


class TransportDto_Seek extends TransportDto {
  const TransportDto_Seek({required this.ms}): super._();
  

 final  BigInt ms;

/// Create a copy of TransportDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TransportDto_SeekCopyWith<TransportDto_Seek> get copyWith => _$TransportDto_SeekCopyWithImpl<TransportDto_Seek>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TransportDto_Seek&&(identical(other.ms, ms) || other.ms == ms));
}


@override
int get hashCode {
    return Object.hash(runtimeType,ms);
}

@override
String toString() {
    return 'TransportDto.seek(ms: $ms)';
}


}

/// @nodoc
abstract mixin class $TransportDto_SeekCopyWith<$Res> implements $TransportDtoCopyWith<$Res> {
  factory $TransportDto_SeekCopyWith(TransportDto_Seek value, $Res Function(TransportDto_Seek) _then) = _$TransportDto_SeekCopyWithImpl;
@useResult
$Res call({
 BigInt ms
});




}
/// @nodoc
class _$TransportDto_SeekCopyWithImpl<$Res>
    implements $TransportDto_SeekCopyWith<$Res> {
  _$TransportDto_SeekCopyWithImpl(this._self, this._then);

  final TransportDto_Seek _self;
  final $Res Function(TransportDto_Seek) _then;

/// Create a copy of TransportDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? ms = null,}) {
  return _then(TransportDto_Seek(
ms: null == ms ? _self.ms : ms // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class TransportDto_Next extends TransportDto {
  const TransportDto_Next(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TransportDto_Next);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TransportDto.next()';
}


}




/// @nodoc


class TransportDto_Previous extends TransportDto {
  const TransportDto_Previous(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TransportDto_Previous);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TransportDto.previous()';
}


}




/// @nodoc


class TransportDto_Stop extends TransportDto {
  const TransportDto_Stop(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TransportDto_Stop);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TransportDto.stop()';
}


}




/// @nodoc


class TransportDto_FromStart extends TransportDto {
  const TransportDto_FromStart(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is TransportDto_FromStart);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'TransportDto.fromStart()';
}


}




// dart format on
