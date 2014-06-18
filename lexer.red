Red [
	Title:   "Red runtime lexer"
	Author:  "Nenad Rakocevic"
	File: 	 %lexer.red
	Tabs:	 4
	Rights:  "Copyright (C) 2014 Nenad Rakocevic. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/dockimbel/Red/blob/master/BSL-License.txt
	}
]

trans-integer: routine [
	start [string!]
	end	  [string!]
	/local
		c	 [integer!]
		n	 [integer!]
		m	 [integer!]
		len  [integer!]
		p	 [byte-ptr!]
		neg? [logic!]
][
	str:  GET_BUFFER(start)
	unit: GET_UNIT(str)
	p:	  string/rs-head start
	len:  end/head - start/head
	neg?: no
	
	c: string/get-char p unit
	if any [
		c = as-integer #"+" 
		c = as-integer #"-"
	][
		neg?: c = as-integer #"-"
		p: p + unit
		len: len - 1
	]
	n: 0
	until [
		c: (string/get-char p unit) - #"0"
		
		m: n * 10
		if m < n [SET_RETURN(none-value) exit]			;-- return NONE on overflow
		n: m
		
		if all [n = 2147483640 c = 8][
			integer/box 80000000h						;-- special exit trap for -2147483648
			exit
		]
		
		m: n + c
		if m < n [SET_RETURN(none-value) exit]			;-- return NONE on overflow
		n: m

		p: p + unit
		len: len - 1
		zero? len
	]
	integer/box either neg? [0 - n][n]
]

trans-decimal: routine [
	start [string!]
	end	  [string!]
][
	float/box string/to-float start end/head - start/head
]

trans-hexa: routine [
	start	[string!]
	end		[string!]
	return: [integer!]
	/local
		s	  [series!]
		unit  [integer!]
		p	  [byte-ptr!]
		head  [byte-ptr!]
		p4	  [int-ptr!]
		n	  [integer!]
		power [integer!]
		cp	  [byte!]
][
	s: GET_BUFFER(start)
	unit: GET_UNIT(s)
	
	p: (string/rs-head end) - unit
	head: string/rs-head start
	
	n: 0
	power: 0
	while [p >= head][
		cp: switch unit [
			Latin1 [p/value]
			UCS-2  [as-byte ((as-integer p/2) << 8 + p/1)]
			UCS-4  [p4: as int-ptr! p as-byte p4/value]
		]
		if cp <> #"0" [
			case [
				all [#"0" <= cp cp <= #"9"][cp: cp - #"0"]
				all [#"A" <= cp cp <= #"F"][cp: cp - #"A" + 10]
				all [#"a" <= cp cp <= #"f"][cp: cp - #"a" + 10]
			]
			n: n + ((as-integer cp) << power)
		]
		power: power + 4
		p: p - unit
	]
	n
]

trans-char: routine [
	start	[string!]
	end		[string!]
	/local
		n	  [integer!]
		value [red-value!]
][
	n: trans-hexa start end
	value: as red-value! integer/box n
	set-type value TYPE_CHAR
]

trans-push-path: routine [
	stack [block!]
	type  [datatype!]
	/local
		path [red-path!]
][
	path: as red-path! block/make-at as red-block! ALLOC_TAIL(stack) 4
	path/header: switch type/value [
		TYPE_GET_WORD [TYPE_GET_PATH]
		TYPE_LIT_WORD [TYPE_LIT_PATH]
		default [TYPE_PATH]
	]
]

trans-set-path: routine [
	stack [block!]
	/local
		path [red-path!]
][
	path: as red-path! block/pick stack 1 null
	set-type as red-value! path TYPE_SET_PATH
]

trans-make-word: routine [
	src   [string!]
	type  [datatype!]
][
	set-type
		as red-value! word/box (symbol/make-alt src) ;-- word/box puts it in stack/arguments
		type/value
]

trans-word: func [
	stack [block!]
	src   [string!]
	type  [datatype!]
][
	trans-store stack trans-make-word src type
]

trans-pop: function [stack [block!]][
	value: last stack
	remove back tail stack
	
	either any [1 < length? stack head? stack/1][
		append/only last stack :value
	][
		pos: back tail stack							;-- root storage and offset-ed series (/into option)
		pos/1: insert/only last stack :value
	]
]

trans-store: function [stack [block!] value][
	either any [1 < length? stack head? stack/1][
		append last stack value
	][
		pos: back tail stack							;-- root storage and offset-ed series (/into option)
		pos/1: insert last stack value
	]
]

transcode: function [
	src	[string!]
	dst	[block! none!]
	/part	
		length [integer! string!]
	return: [block!]
	/local
		new s e c hex pos value cnt type process
		digit hexa-upper hexa-lower hexa hexa-char not-word-char not-word-1st
		not-file-char not-str-char not-mstr-char caret-char
		non-printable-char integer-end ws-ASCII ws-U+2k control-char
][
	cs:		[- - - - - - - - - - - - - - - -]			;-- memoized bitsets
	stack:	clear []
	count?:	yes											;-- if TRUE, lines counter is enabled
	line: 	1
	
	append/only stack any [dst make block! 4]
	
	trans-string: [
		new: make type (index? e) - index? s
		parse/case copy/part s e [						;@@ add /part option to parse!
			any [
				escaped-char (append new value)
				| #"^^"									;-- trash single caret chars
				| set c skip (append new c)
			]
		]
		new
	]

	trans-file: [
		new: make type (index? e) - index? s
		append new dehex copy/part s e
		new
	]
	
	if cs/1 = '- [
		cs/1:  charset "0123465798"						;-- digit
		cs/2:  charset "ABCDEF"							;-- hexa-upper
		cs/3:  charset "abcdef"							;-- hexa-lower
		cs/4:  union cs/1 cs/2							;-- hexa
		cs/5:  union cs/4 cs/3							;-- hexa-char	
		cs/6:  charset {/\^^,[](){}"#%$@:;}				;-- not-word-char
		cs/7:  union union cs/6 cs/1 charset {'}		;-- not-word-1st
		cs/8:  charset {[](){}"@:;}						;-- not-file-char
		cs/9:  #"^""									;-- not-str-char
		cs/10: #"}"										;-- not-mstr-char
		cs/11: charset [#"^(40)" - #"^(5F)"]			;-- caret-char
		cs/12: charset [#"^(00)" - #"^(1F)"]			;-- non-printable-char
		cs/13: charset {^{"[]);}						;-- integer-end
		cs/14: charset " ^-^M"							;-- ws-ASCII, ASCII common whitespaces
		cs/15: charset [#"^(2000)" - #"^(200A)"]			;-- ws-U+2k, Unicode spaces in the U+2000-U+200A range
		cs/16: charset [#"^(00)" - #"^(1F)"] 			;-- ASCII control characters

	]
	set [
		digit hexa-upper hexa-lower hexa hexa-char not-word-char not-word-1st
		not-file-char not-str-char not-mstr-char caret-char
		non-printable-char integer-end ws-ASCII ws-U+2k control-char
	] cs
	
	;-- Whitespaces list from: http://en.wikipedia.org/wiki/Whitespace_character
	ws: [
		pos: #"^/" (
			if count? [
				line: line + 1 
				;append/only lines to block! stack/tail?
			]
		)
		| ws-ASCII										;-- only the common whitespaces are matched
		| #"^(0085)"									;-- U+0085 (Newline)
		| #"^(00A0)"									;-- U+00A0 (No-break space)
		| #"^(1680)"									;-- U+1680 (Ogham space mark)
		| #"^(180E)"									;-- U+180E (Mongolian vowel separator)
		| ws-U+2k										;-- U+2000-U+200A range
		| #"^(2028)"									;-- U+2028 (Line separator)
		| #"^(2029)"									;-- U+2029 (Paragraph separator)
		| #"^(202F)"									;-- U+202F (Narrow no-break space)
		| #"^(205F)"									;-- U+205F (Medium mathematical space)
		| #"^(3000)"									;-- U+3000 (Ideographic space)
	]

	newline-char: [
		#"^/"
		| #"^(0085)"									;-- U+0085 (Newline)
		| #"^(2028)"									;-- U+2028 (Line separator)
		| #"^(2029)"									;-- U+2029 (Paragraph separator)
	]

	counted-newline: [pos: #"^/" (line: line + 1)]

	ws-no-count: [(count?: no) ws (count?: yes)]

	escaped-char: [
		"^^(" [
			[										;-- special case first
				"null" 	 (value: #"^(00)")
				| "back" (value: #"^(08)")
				| "tab"  (value: #"^(09)")
				| "line" (value: #"^(0A)")
				| "page" (value: #"^(0C)")
				| "esc"  (value: #"^(1B)")
				| "del"	 (value: #"^(7F)")
			]
			| pos: [1 6 hexa-char] e: (				;-- Unicode values allowed up to 10FFFFh
				value: trans-char pos e
			)
		] #")"
		| #"^^" [
			[
				#"/" 	(value: #"^/")
				| #"-"	(value: #"^-")
				| #"?" 	(value: #"^(del)")			;@@FIXME
				| #"^^" (value: #"^^")				;-- caret escaping case
				| #"{"	(value: #"{")
				| #"}"	(value: #"}")
				| #"^""	(value: #"^"")
			]
			| pos: caret-char (value: pos/1 - 64)
		]
	]

	char-rule: [
		{#"} s: [
			 escaped-char
			| ahead [non-printable-char | not-str-char] break
			| skip (value: s/1)
		] {"}
	]
	
	line-string: [
		{"} s: any [
			{^^"}
			| ahead [#"^"" | newline-char] break
			| escaped-char
			| skip
		]
		e: {"}
	]
	
	nested-curly-braces: [
		(cnt: 1)
		any [
			counted-newline 
			| "^^{" 
			| "^^}"
			| #"{" 	  (cnt: cnt + 1)
			| e: #"}" if (zero? cnt: cnt - 1) break
			| escaped-char
			| skip
		]
	]
	
	multiline-string: [#"{" s: nested-curly-braces]
	
	string-rule: [(type: string!) line-string | multiline-string]
	
	file-rule: [
		#"%" [
			line-string (process: trans-string type: file!)
			| s: any [ahead [not-file-char | ws-no-count] break | skip] e:
			  (process: trans-file type: file!)
		]
	]

	url-rule: [
		#":" not [integer-end | ws-no-count | end]
		any [#"@" | #":" | ahead [not-file-char | ws-no-count] break | skip] e:
		(type: url! trans-store stack do trans-file)
	]

	symbol-rule: [
		some [ahead [not-word-char | ws-no-count | control-char] break | skip] e:
	]

	begin-symbol-rule: [								;-- 1st char in symbols is restricted
		[not ahead [not-word-1st | ws-no-count | control-char]]
		symbol-rule
	]

	path-rule: [
		ahead slash (									;-- path detection barrier
			trans-push-path stack type					;-- create empty path
			trans-word stack copy/part s e word!		;-- push 1st path element
		)
		some [
			slash
			s: [
				integer-number-rule			(trans-store stack trans-integer s e)
				| begin-symbol-rule			(trans-word stack copy/part s e word!)
				| paren-rule
				| #":" s: begin-symbol-rule	(trans-word stack copy/part s e get-word!)
				;@@ add more datatypes here
				| (type: none print ["*** Syntax Error: invalid path value at:" back s])
				  reject
			]
			opt [#":" (trans-set-path back tail stack)]
		] (trans-pop stack)
	]

	word-rule: 	[
		#"%" ws-no-count (trans-word stack "%" word!)	;-- special case for remainder op!
		| s: begin-symbol-rule (type: word!) [
				url-rule
				| path-rule								;-- path matched
				| opt [#":" (type: set-word!)]
				  (if type [trans-word stack copy/part s e type])	;-- word or set-word matched
		  ]
	]

	get-word-rule: [
		#":" (type: get-word!) s: begin-symbol-rule [
			path-rule (type: get-path!)
			| (trans-word stack copy/part s e type)		;-- get-word matched
		]
	]

	lit-word-rule: [
		#"'" (type: lit-word!) s: begin-symbol-rule [
			path-rule (type: lit-path!)					;-- path matched
			| (trans-word stack copy/part s e type)		;-- lit-word matched
		]
	]

	issue-rule: [
		#"#" (type: issue!) s: symbol-rule 
		(trans-word stack copy/part s e type)
	]

	refinement-rule: [
		slash [
			some slash (type: word!) e:					;--  ///... case
			| ahead [not-word-char | ws-no-count | control-char] (type: word!) e: ;-- / case
			| symbol-rule (type: refinement! s: next s)
		]
		(trans-word stack copy/part s e type)
	]

	hexa-rule: [2 8 hexa e: #"h"]
	
	integer-number-rule: [
		opt [#"-" | #"+"] digit any [digit | #"'" digit] e:
	]
	
	integer-rule: [
		integer-number-rule
		ahead [integer-end | ws-no-count | end]
	]

	decimal-number-rule: [
		[opt [#"-" | #"+"] digit any [digit | #"'" digit] | ahead #"."]		;-- first part
		opt [[#"." | #","] any digit]							;-- second part
		opt [opt [#"e" | #"E"] opt [#"-" | #"+"] some digit]	;-- third part
		e:
 	]
 	
 	decimal-rule: [
 		decimal-number-rule
 		ahead [integer-end | ws-no-count | end]
 	]
	
	block-rule: [
		#"[" (append/only stack make block! 4)
		any-value
		#"]" (trans-pop stack)
	]
	
	paren-rule: [
		#"(" (append/only stack make paren! 4)
		any-value 
		#")" (trans-pop stack)
	]
	
	escaped-rule: [
		"#[" pos: any ws [
			  "true"  			(value: true)
			| "false" 			(value: false)
			| [
				"none!"			(value: none!)
				| "logic!"		(value: logic!)
				| "block!"		(value: block!)
				| "integer!"	(value: integer!)
				| "word!"		(value: word!)
				| "set-word!"	(value: set-word!)
				| "get-word!"	(value: get-word!)
				| "lit-word!"	(value: lit-word!)
				| "refinement!"	(value: refinement!)
				;| "binary!"	(value: binary!)
				| "string!"		(value: string!)
				| "char!"		(value: char!)
				| "bitset!"		(value: bitset!)
				| "path!"		(value: path!)
				| "set-path!"	(value: set-path!)
				| "lit-path!"	(value: lit-path!)
				| "get-path!"	(value: get-path!)
				| "native!"		(value: native!)
				| "action!"		(value: action!)
				| "op!"			(value: op!)
				| "issue!"		(value: issue!)
				| "paren!"		(value: paren!)
				| "function!"	(value: function!)
				| "routine!"	(value: routine!)
			]
			| "none" 			(value: none)
		] pos: any ws #"]"
	]
	
	comment-rule: [#";" [to lf | to end]]
	
	wrong-delimiters: [
		pos: [
			  #"]" (value: #"[") | #")" (value: #"(")
			| #"[" (value: #"]") | #"(" (value: #")")
		] :pos
		(print ["missing matching" value])
	]
	
	literal-value: [
		pos: (e: none) s: [
			comment-rule
			| escaped-rule		(trans-store stack value)
			| integer-rule		if (value: trans-integer s e ) (trans-store stack value)
			| decimal-rule		if (value: trans-decimal s e ) (trans-store stack value)
			| hexa-rule			(trans-store stack trans-hexa s e)
			| word-rule
			| lit-word-rule
			| get-word-rule
			| refinement-rule
			| file-rule			(trans-store stack value: do process)
			| char-rule			(trans-store stack value)
			| issue-rule
			| block-rule
			| paren-rule
			| string-rule		(trans-store stack do trans-string)
			;| binary-rule	  	(stack/push load-binary s e)
		]
	]
	
	any-value: [pos: any [literal-value | ws]]

	red-rules: [any-value opt wrong-delimiters]
	
	unless either part [
		parse/case/part src red-rules length
	][
		parse/case src red-rules
	][
		print ["*** Syntax Error: invalid Red value at:" copy/part pos 20]
	]
	stack/1
]