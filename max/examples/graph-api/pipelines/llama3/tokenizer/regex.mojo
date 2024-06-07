# ===----------------------------------------------------------------------=== #
# Copyright (c) 2024, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""POSIX 2 regular expressions via regcomp/regexec."""

from sys.info import os_is_macos
from _mlir._c.ffi import MLIR_func


def set_locale_unicode():
    empty_string = str("")
    locale = external_call["setlocale", UnsafePointer[UInt8]](
        0, Reference(empty_string.as_bytes_slice()[0])
    )  # LC_ALL
    if not locale:
        raise "didn't set locale"


struct ExecuteOption:
    alias STARTEND = 4


struct CompileOption:
    alias EXTENDED = 1
    alias ICASE = 2
    alias ENHANCED = 0o400


fn llvm_regcomp(ptr: UnsafePointer[_CRegex], pattern: String, mode: Int) -> Int:
    return MLIR_func[
        "llvm_regcomp",
        fn (UnsafePointer[_CRegex], UnsafePointer[Int8], Int) -> Int,
    ]()(ptr, pattern.unsafe_ptr(), mode)


fn llvm_regexec(
    ptr: UnsafePointer[_CRegex],
    string: String,
    inout pmatch: List[_CRegexMatch],
    mode: Int,
) -> Int:
    return MLIR_func[
        "llvm_regexec",
        fn (
            UnsafePointer[_CRegex],
            UnsafePointer[Int8],
            Int,
            UnsafePointer[_CRegexMatch],
            Int,
        ) -> Int,
    ]()(ptr, string.unsafe_ptr(), len(pmatch), pmatch.unsafe_ptr(), mode)


fn llvm_regfree(ptr: UnsafePointer[_CRegex]):
    return MLIR_func["llvm_regfree", fn (UnsafePointer[_CRegex]) -> NoneType]()(
        ptr
    )


fn llvm_regerror(
    error: Int,
    ptr: UnsafePointer[_CRegex],
    message: UnsafePointer[UInt8],
    max_size: Int,
) -> Int:
    return MLIR_func[
        "llvm_regerror",
        fn (Int, UnsafePointer[_CRegex], UnsafePointer[UInt8], Int) -> Int,
    ]()(error, ptr, message, max_size)


struct _CRegex:
    # This corresponds to the llvm_regex_t type definition.
    var _magic: Int
    var capture_groups: Int
    var _re_endp: UnsafePointer[NoneType]
    var _re_guts: UnsafePointer[NoneType]
    var _initialized: Bool

    fn __init__(inout self):
        self._magic = 0
        self.capture_groups = 0
        self._re_endp = UnsafePointer[NoneType]()
        self._re_guts = UnsafePointer[NoneType]()
        self._initialized = False

    fn __moveinit__(inout self, owned existing: Self):
        # _CRegex can't be safely moved once it's initialized.
        # We have to implement __move__ currently to satisfy Arc's Movable
        # trait bounds.
        self.__init__()

    fn __del__(owned self):
        if self._initialized:
            llvm_regfree(self._ptr())

    @staticmethod
    def compile(pattern: String, options: Int = 0) -> Arc[Self]:
        self = Arc(Self())
        self[]._compile(pattern, options | CompileOption.EXTENDED)
        return self

    def _compile(inout self, pattern: String, options: Int):
        err = llvm_regcomp(self._ptr(), pattern, options)
        if err:
            raise self._error(err)
        self._initialized = True

    def exec(self, string: String, start: Int = 0) -> List[_CRegexMatch]:
        # This list should be able to be stack-allocated to avoid a heap
        # allocation when there's no match. stack_allocation currently
        # only supports static allocation sizes.
        max_groups = self.capture_groups + 1
        matches = List[_CRegexMatch](capacity=max_groups)
        matches.append(_CRegexMatch(start, len(string)))
        matches.size = max_groups
        no_match = llvm_regexec(
            self._ptr(), string, matches, ExecuteOption.STARTEND
        )
        if no_match:
            return List[_CRegexMatch]()
        return matches^

    def _error(self, code: Int) -> String:
        alias MAX_ERROR_LENGTH = 2048
        message = UnsafePointer[UInt8].alloc(MAX_ERROR_LENGTH)
        size = llvm_regerror(code, self._ptr(), message, MAX_ERROR_LENGTH)
        return "regex error: " + String(message, size)

    fn _ptr(self) -> UnsafePointer[Self]:
        return UnsafePointer.address_of(self)


@value
struct _CRegexMatch:
    var start: Int
    var end: Int

    fn __bool__(self) -> Bool:
        return self.start != -1

    fn __repr__(self) -> String:
        return (
            str("_Group(start=")
            + str(self.start)
            + ", end="
            + str(self.end)
            + ")"
        )


@value
struct _MatchIter[
    regex_lifetime: ImmutableLifetime,
    string_lifetime: ImmutableLifetime,
]:
    var regex: Reference[Regex, False, regex_lifetime]
    var string: Reference[String, False, string_lifetime]
    var start: Int
    var next_match: Optional[Match[string_lifetime]]
    # This is a workaround for not having negative lookaheads, expect this
    # interface to change. This allows using capture groups to tell the regex
    # to "match" only part of the match, and continue at the end of the capture
    # group.
    var negative_lookahead_hack: Bool

    def __init__(
        inout self,
        regex: Reference[Regex, False, regex_lifetime],
        string: Reference[String, False, string_lifetime],
        negative_lookahead_hack: Bool = False,
    ):
        self.regex = regex
        self.string = string
        self.start = 0
        self.next_match = None
        self.negative_lookahead_hack = negative_lookahead_hack
        self._next()

    fn __iter__(self) -> Self:
        return self

    def __next__(inout self) -> Match[string_lifetime]:
        m = self.next_match.value()[]
        self._next()
        return m^

    fn __len__(self) -> Int:
        return int(Bool(self.next_match))

    def _next(inout self):
        m = self.regex[].find(self.string[], start=self.start)
        self.next_match = m
        if m and self.negative_lookahead_hack:
            # End the regex at the end of the last capture group,
            # or at the end of the match if none are populated.
            max_end = self.start
            for i in range(1, len(m.value()[]._groups)):
                group = m.value()[]._groups[i]
                if group and group.end > max_end:
                    max_end = group.end
            if max_end == self.start:
                max_end = m.value()[].end()
            self.start = max_end
            self.next_match.value()[]._groups[0].end = max_end
        else:
            self.start = m.value()[].end() if m else len(self.string[])


@value
struct Match[lifetime: ImmutableLifetime]:
    var _string: Span[UInt8, False, lifetime]
    var _groups: List[_CRegexMatch]

    fn __getitem__(self, group: Int) -> StringSlice[False, lifetime]:
        var m = self._groups[group]
        return StringSlice(unsafe_from_utf8=self._string[m.start : m.end])

    fn __str__(self) -> String:
        return str(self[0])

    fn __len__(self) -> Int:
        return self.end() - self.start()

    fn start(self) -> Int:
        return self._groups[0].start

    fn end(self) -> Int:
        return self._groups[0].end

    fn __repr__(self) -> String:
        return (
            str("Match(start=")
            + str(self.start())
            + ", end="
            + str(self.end())
            + ", match="
            + repr(str(self))
            + ")"
        )


@value
struct Regex:
    var _c: Arc[_CRegex]

    def __init__(inout self, pattern: String, options: Int = 0):
        self._c = _CRegex.compile(pattern, options)

    def find(
        self, string: String, start: Int = 0
    ) -> Optional[Match[__lifetime_of(string)]]:
        groups = self._c[].exec(string, start=start)
        if groups:
            return Match(string.as_bytes_slice(), groups^)
        return None

    def findall(
        self, string: String, negative_lookahead_hack: Bool = False
    ) -> _MatchIter[__lifetime_of(self), __lifetime_of(string)]:
        return _MatchIter(self, string, negative_lookahead_hack)
