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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( TransportDto_PlayFile value)?  playFile,TResult Function( TransportDto_Pause value)?  pause,TResult Function( TransportDto_Resume value)?  resume,TResult Function( TransportDto_Seek value)?  seek,TResult Function( TransportDto_Stop value)?  stop,required TResult orElse(),}){
final _that = this;
switch (_that) {
case TransportDto_PlayFile() when playFile != null:
return playFile(_that);case TransportDto_Pause() when pause != null:
return pause(_that);case TransportDto_Resume() when resume != null:
return resume(_that);case TransportDto_Seek() when seek != null:
return seek(_that);case TransportDto_Stop() when stop != null:
return stop(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( TransportDto_PlayFile value)  playFile,required TResult Function( TransportDto_Pause value)  pause,required TResult Function( TransportDto_Resume value)  resume,required TResult Function( TransportDto_Seek value)  seek,required TResult Function( TransportDto_Stop value)  stop,}){
final _that = this;
switch (_that) {
case TransportDto_PlayFile():
return playFile(_that);case TransportDto_Pause():
return pause(_that);case TransportDto_Resume():
return resume(_that);case TransportDto_Seek():
return seek(_that);case TransportDto_Stop():
return stop(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( TransportDto_PlayFile value)?  playFile,TResult? Function( TransportDto_Pause value)?  pause,TResult? Function( TransportDto_Resume value)?  resume,TResult? Function( TransportDto_Seek value)?  seek,TResult? Function( TransportDto_Stop value)?  stop,}){
final _that = this;
switch (_that) {
case TransportDto_PlayFile() when playFile != null:
return playFile(_that);case TransportDto_Pause() when pause != null:
return pause(_that);case TransportDto_Resume() when resume != null:
return resume(_that);case TransportDto_Seek() when seek != null:
return seek(_that);case TransportDto_Stop() when stop != null:
return stop(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String path)?  playFile,TResult Function()?  pause,TResult Function()?  resume,TResult Function( BigInt ms)?  seek,TResult Function()?  stop,required TResult orElse(),}) {final _that = this;
switch (_that) {
case TransportDto_PlayFile() when playFile != null:
return playFile(_that.path);case TransportDto_Pause() when pause != null:
return pause();case TransportDto_Resume() when resume != null:
return resume();case TransportDto_Seek() when seek != null:
return seek(_that.ms);case TransportDto_Stop() when stop != null:
return stop();case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String path)  playFile,required TResult Function()  pause,required TResult Function()  resume,required TResult Function( BigInt ms)  seek,required TResult Function()  stop,}) {final _that = this;
switch (_that) {
case TransportDto_PlayFile():
return playFile(_that.path);case TransportDto_Pause():
return pause();case TransportDto_Resume():
return resume();case TransportDto_Seek():
return seek(_that.ms);case TransportDto_Stop():
return stop();}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String path)?  playFile,TResult? Function()?  pause,TResult? Function()?  resume,TResult? Function( BigInt ms)?  seek,TResult? Function()?  stop,}) {final _that = this;
switch (_that) {
case TransportDto_PlayFile() when playFile != null:
return playFile(_that.path);case TransportDto_Pause() when pause != null:
return pause();case TransportDto_Resume() when resume != null:
return resume();case TransportDto_Seek() when seek != null:
return seek(_that.ms);case TransportDto_Stop() when stop != null:
return stop();case _:
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




// dart format on
