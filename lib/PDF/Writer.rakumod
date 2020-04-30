use v6;

class PDF::Writer {

    use PDF::Grammar:ver(v0.2.1+);
    use PDF::IO;
    use PDF::IO::Util;
    use PDF::COS::Type::XRef;
    use PDF::IO::IndObj;

    has PDF::IO $!input;
    has $.ast is rw;
    has UInt $.offset;
    has UInt $.prev;
    has UInt $.size;
    has Str  $.indent is rw = '';
    has Version $.compat = v1.4;

    submethod TWEAK(:$input) {
        $!input .= coerce( $_ )
            with $input;
    }

    method Str returns Str {
        with $.ast {
            temp $!offset;
            temp $!prev;
            $.write( $_ );
        }
        else {
            nextsame;
        }
    }

    method Blob returns Blob {
	self.Str.encode: "latin-1";
    }

    method write-array(List $_ ) {
	temp $!indent ~= '  ';  # for indentation of child dictionarys
	('[', .map({ $.write($_) }), ']').join: ' ';
    }

    multi method write-body(List $_, |c ) {
        temp $!prev = Nil;
        .map({ $.write-body( $_, |c )}).join: "\n";
    }

    multi method write-body( Hash $body, |c ) {
	$!offset //= 0;
	$.write-body( $body, |c );
    }

    #| write the body and return the index
    multi method write-body( Hash $body!, @idx = [], Bool :$write-xref = True --> Str ) {
	@idx.unshift: { :type(0), :offset(0), :gen-num(65535), :obj-num(0) };
	my @out = self!make-objects( $body<objects>, @idx );

	my \trailer-dict = $body<trailer> // {};
	my \trailer-bytes = $write-xref
            ?? self!make-trailer( trailer-dict, @idx )
            !! [~] ( $.write-trailer( trailer-dict ), '%%EOF' );

        @out.push: trailer-bytes;
        $!offset += trailer-bytes.codes  +  2 * "\n".codes;

        @out.join: "\n";
    }

    method !make-objects( @objects, @idx = [] ) {
        @objects.map: -> $obj is rw {
            my \bytes = do with $obj<ind-obj> -> $ind-obj {
                # serialization of in-memory object
		my uint $obj-num = $ind-obj[0];
		my uint $gen-num = $ind-obj[1];
		@idx.push: %( :type(1), :$!offset, :$gen-num, :$obj-num, :$ind-obj );

                $.write-ind-obj( $ind-obj );
            }
            elsif my \ref = $obj<copy> {
                # direct copy of raw object from input to output
		my uint $obj-num = ref[0];
		my uint $gen-num = ref[1];
                my $getter = ref[2];
                my $ind-obj = $getter.get($obj-num, $gen-num);
		@idx.push: %( :type(1), :$!offset, :$gen-num, :$obj-num, :$ind-obj );
                $.write-ind-obj( $ind-obj );
            }
            elsif my \comment = $obj<comment> {
                $.write-comment(comment);
            }
            else {
                die "don't know how to serialize body component: {$obj.perl}"
            }

            $!offset += bytes.codes + 1;
            bytes;
        }
    }

    method !make-trailer($dict, @idx) {
        $!compat >= v1.5
            ?? self!make-trailer-stream($dict, @idx)
            !! self!make-trailer-xref($dict, @idx);
    }

    #| build a PDF 1.5+ Cross Reference Stream
    method !make-trailer-stream( Hash $trailer, @idx ) {
	my UInt \startxref = $.offset;
        my %dict = %$trailer<dict>;
        my PDF::COS::Type::XRef $xref .= new: :%dict;
        $xref.Filter = 'FlateDecode';
        my $n := +@idx;
        my uint64 @xref-index[$n;4];
        with @idx.tail<obj-num> {
            $!size = $_ + 1
                if !$!size || $!size <= $_;
        }

        for 0 ..^ $n -> $i {
            my $idx := @idx[$i];
            my UInt $type := $idx<type>;
            my $obj-num := $idx<obj-num>;
            @xref-index[$i;0] = $obj-num;
            @xref-index[$i;1] = $type;
            @xref-index[$i;2] = do given $type {
                when 0 { $!size }
                when 1 { $idx<offset> }
                when 2 { $idx<ref-obj-num> }
            }
            @xref-index[$i;3] = do given $type {
                when 0 { $idx<gen-num> + 1 }
                when 1 { $idx<gen-num> }
                when 2 { $idx<index> }
            }
        }

        $xref.encoded = $xref.encode-index: @xref-index;
        my $xref-obj = PDF::IO::IndObj.new: :object($xref), :obj-num($!size), :gen-num(0);

        my \xref-str = self.write($xref-obj.ast);

	my \trailer = [~] (
	    xref-str,
	    $.write-startxref( startxref ),
	    '%%EOF',
        );

	$!offset += xref-str.codes;
	$!prev = startxref;

        trailer;
    }

    #| Build a PDF 1.4- Cross Reference Table
    method !make-trailer-xref( Hash $trailer, @idx ) {
        my uint $total-entries = +@idx;
	my uint64 @idx-sorted[+$total-entries;4] = @idx.sort({ $^a<obj-num> <=> $^b<obj-num> || $^a<gen-num> <=> $^b<gen-num> })
                                                       .map: {[.<type>, .<obj-num>, .<gen-num>, .<offset> ]};

	my Str \xref-str = self!write-xref-segments: self!xref-segments( @idx-sorted );
	my UInt \startxref = $.offset;

	my \trailer = [~] (
	    xref-str,
	    $.write-trailer( $trailer, :$!prev, :$!size ),
	    $.write-startxref( startxref ),
	    '%%EOF',
        );

	$!offset += xref-str.codes;
	$!prev = startxref;

        trailer;
    }

    method write-bool( $_ ) {
        .so ?? 'true' !! 'false';
    }

    #| inverter for PDF::Grammar::Content::Actions

    multi method write-content(List $_ ) {
        .map({ $.write-content($_) }).join("\n");
    }

    multi method write-content($_ where Pair | Hash) {
        my ($op, $args) = .kv;
        $args //= [];
        $.write-op($op, |@$args);
    }

    multi method write-content( Str $_ ) { $_ }

    #| BI <dict> - BeginImage
    multi method write-op('BI', $arg = :dict{}) {
        my Hash $entries = $arg<dict>;
	join( "\n",
              "BI",
              self!indented($entries.pairs.sort,
                            -> $_ { [~] $.write-name( .key ), ' ', $.write( .value ) }
                           ),
            );
    }

   multi method write-op('comment', $_) { $.write-comment($_); }

    #| ID <bytes> - ImageData
    multi method write-op('ID', $image-data) {
        "ID\n" ~ $image-data<encoded>;
    }

    multi method write-op(Str $op, *@args) is default {
        my @vals;
        my @comments;
        for @args -> \arg {
            with arg<comment> {
                @comments.push: $_;
            }
            else {
                @vals.push: arg;
            }
        }

        my @out = @vals.map: {$.write($_)};
        @out.push: $.write-op( $op );
        @out.push: $.write-comment( @comments.join(' ') )
            if @comments;

        @out.join: ' ';
    }

    multi method write-op( Str $_ ) { .Str }

    multi method write-comment(List $_) {
        .map({ $.write-comment($_) }).join: "\n";
    }

    multi method write-comment(Str $_) {
        # sanitize non-latin characters
        given .subst(/<- [ \x0..\xFF ]>/, *.ord.fmt('#%x') , :g) {
            .starts-with('%') ?? $_ !! '% ' ~ $_
        }
    }

    method write-dict(Hash $dict) {

        # prioritize /Type and /Subtype entries. output /Length as last entry
        my @keys = $dict.keys.sort: {
            when 'Type'              {"0"}
            when 'Subtype'|'S'       {"1"}
            when .ends-with('Type')  {"1" ~ $_}
            when 'Length'            {"z"}
            default                  {$_}
        };
        my $pad = $!indent;
        temp $!indent ~= '  ';  # for indentation of child dictionarys
        my @entries = @keys.map({ $.write-name($_) ~ ' ' ~ $.write( $dict{$_} ); });
        my $len = $!indent;
        for @entries {
            $len += .chars;
            last if $len > 64;
        }

        $len > 64
            ?? join("\n", '<<', @entries.map({$!indent ~ $_}), $pad ~ '>>')
            !! join(' ', '<<', @entries, '>>');
    }

    #| invertors for PDF::Grammar::Function expr term
    #| an array is a sequence of sub-expressions
    multi method write-expr(List $_) {
	[~] '{ ', .map({ $.write($_) }).join(' '), ' }';
    }

    #| 'if' and 'ifelse' functional expressions
    multi method write-expr(% (:$if!, :$else) ) {
        my @expr = $.write( $if );
        @expr.append: do with $else {
	    ($.write( $_ ), 'ifelse');
        }
        else {
	    ('if')
        }
        @expr.join: ' ';
    }


    method write-hex-string( Str $_ ) {
        [~] flat '<', .encode("latin-1").map({ 
            .fmt: '%02x';
        }), '>';
    }

    method write-ind-obj(@_) {
        my (UInt \obj-num, UInt \gen-num, \object where Pair | Hash) = @_;

        "%d %d obj\n%s\nendobj\n".sprintf(obj-num, gen-num, $.write( object ));
    }

    method write-ind-ref(List $_) {
        join(' ', .[0], .[1], 'R');
    }

    method write-int(Int $_) {.fmt: '%d'}

    constant %Escapes = %(
        "\b" => '\\b', "\f" => '\\f', "\n" => '\\n', "\r" => '\\r',
        "\t" => '\\t', '(' => '\\(', ')' => '\\)', '\\' => '\\\\' );

    method write-literal( Str $_ ) {

        [~] flat '(',
        .encode("latin-1").map({
                my \c = .chr;
                %Escapes{c} // c
            }),
           ')';
    }

    constant Name-Reg-Chars = set ('!'..'~').grep({ $_ !~~ /<PDF::Grammar::char-delimiter>/});

    method write-name( Str $_ ) {
        [~] flat '/', .comb.map( {
            when $_ ∈ Name-Reg-Chars { $_ }
            when '#' { '##' }
            default {
                .encode.list.map({.fmt('#%02x')}).join('');
            }
        } )
    }

    method write-null( $ ) { 'null' }

    method write-cos(% (:$header!, :$body!, :$comment = q<%¥±ë¼>) ) {
        my Str \header = $.write-header( $header );
        my Str \comment = $.write-comment($comment);
        $!offset = header.codes + comment.codes + 2;  # since format is byte orientated
        # Form Definition Format is normally written without an xref
        my Str \type = $header<type> // 'PDF';
	my Bool $write-xref = type ne 'FDF';
        my \body = $.write-body( $body, :$write-xref );
        (header, comment, body).join: "\n";
    }

    method write-header($_ ) {
        my Str \type = .<type> // 'PDF';
        '%%%s-%.1f'.sprintf(type, .<version> // 1.2);
    }

    multi method write-real( Int $_ ) {
        .fmt: '%d';
    }

    multi method write-real( Numeric $_ ) {
        my Str $num = .fmt('%.5f');
        $num ~~ s/(\.\d*?)0+$/$0/;
        $num.ends-with('.') ?? $num.chop !! $num;
    }

    method write-stream(% (:%dict!, :$encoded = $.input.stream-data( :stream($_) )) ) {
        my $data = $encoded;
        $data .= decode("latin-1")
            unless $data.isa(Str);
        %dict<Length> //= :int($data.codes);
        [~] $.write-dict(%dict), " stream\n", $data, "\nendstream";
    }

    method write-trailer(% (:%dict), :$prev) is default {

        %dict<Prev> = :int($_)
            with $prev;

        %dict<Size> = :int($_)
            with $!size;

        [~] "trailer\n", $.write-dict(%dict), "\n";
    }

    method write-startxref(UInt $_ ) {
        "startxref\n" ~ $.write-int($_) ~ "\n"
    }

    method !xref-segment-length($xref where .shape[1] ~~ 4, $i, $n) {
        my $next-obj-num = $xref[$i;1];
        loop (my $j = $i; $j < $n && $next-obj-num == $xref[$j;1]; $j++) {
            $next-obj-num++;
        }
        $j - $i;
    }

    method !xref-segments(@idx) {
        my $total-entries := +@idx;
        given @idx[$total-entries-1;1] + 1 {
            $!size = $_
                if !$!size || $_ > $!size;
        }
        my Hash @xrefs;
        loop (my uint $i = 0; $i < $total-entries;) {
            my uint $obj-count = self!xref-segment-length(@idx, $i, $total-entries);
            my uint32 $obj-first-num = @idx[$i;1];

	    # [ PDF 32000 7.5.4 Cross-Reference Table:
	    # "Each cross-reference subsection contains entries for a contiguous range of object numbers"]
            my uint64 @entries[$obj-count;3];
            for 0 ..^ $obj-count {
                my uint8  $type    = @idx[$i;0];
                my uint32 $gen-num = @idx[$i;2];
                my uint64 $offset  = @idx[$i;3];
                @entries[$_;0] = $offset;
                @entries[$_;1] = $gen-num;
                @entries[$_;2] = $type;
                $i++;
            }
	    @xrefs.push: %( :$obj-first-num, :$obj-count, :@entries );
        }
        @xrefs;
    }

    method !write-xref-segments(List $_) {
        "xref\n" ~ .map({ self!write-xref-section(|$_) }).join;
    }

    #| write a traditional (PDF 1.4-) cross reference table
    method !write-xref-section(:$obj-first-num!, :$obj-count!, :$entries!) {
        die "xref $obj-count != {$entries.elems}"
            unless $obj-count == +$entries;
         $obj-first-num ~ ' ' ~ $obj-count ~ "\n"
             ~ self!write-entries($entries );
    }

    method !write-entries($_ where .shape[1] ~~ 3) {
        enum Str ( :Free<f>, :Inuse<n> );
        ((0 ..^ .elems).map: -> int $i {
            my uint64 $offset  = .[$i;0];
            my uint32 $gen-num = .[$i;1];
            my uint32 $type    = .[$i;2];
            my Str $status = do given $type {
                when (0) {Free}
                when (1) {Inuse}
                when (2) { die "unable to write type-2 (embedded) objects in a PDF 1.4 cross reference table"}
                default  { die "unhandled index type: $_" }
            };
            die "generation number $gen-num exceeds 5 digits in PDF 1.4 cross reference table"
                if $gen-num > 99_999;
            die "offset $offset exceeds 10 digits in PDF 1.4 cross reference table"
                if $offset > 9_999_999_999;
            "%010d %05d %s \n".sprintf($offset, $gen-num, $status)
        }).join;
    }

    proto method write(|c) returns Str {*}

    constant fast-track = set <hex-string literal name real entries>;

    multi method write( Pair $_!) {
        state $fast-writer;
        state $have-pdf-native //= PDF::IO::Util::have-pdf-native()
        ?? do { $fast-writer = (require ::('PDF::Native::Writer')); True }
        !! False;
        
        given ($have-pdf-native && .key ∈ fast-track
               ?? $fast-writer
               !! self) -> $writer {
            $writer."write-{.value.defined ?? .key !! 'null'}"( .value );
        }
    }

    multi method write( Hash $ast!) {
        $.write( |$ast );
    }

    multi method write( *@args, *%opt ) is default {
        die "unexpected arguments: {[@args].perl}"
            if @args;

        my $key = %opt.keys.sort.first({  $.can("write-$_") })
            or die "unable to handle {%opt.keys} struct: {%opt.perl}";
        my $val = %opt{$key}:delete;
        self."write-$key"($val, |%opt);
    }

    #| handle indentation.
    method !indented(@lines, &sub) {
        temp $!indent ~= '  ';
        @lines ?? @lines.map({ $!indent ~ &sub($_) }).join("\n") !! ();
    }
}
