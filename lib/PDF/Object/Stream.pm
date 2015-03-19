use v6;

use PDF::Tools::Filter;
use PDF::Object :to-ast-native;
use PDF::Object :from-ast;
use PDF::Object::Type;
use PDF::Object::Tree;

#| Stream - base class for specific stream objects, e.g. Type::ObjStm, Type::XRef, ...
class PDF::Object::Stream
    is PDF::Object
    is Hash
    does PDF::Object::Type 
    does PDF::Object::Tree {

    our %obj-cache = (); #= to catch circular references

    method new(Hash :$dict = {}, *%etc) {
        my $id = ~$dict.WHICH;
        my $obj = %obj-cache{$id};
        unless $obj {
            temp %obj-cache{$id} = $obj = self.bless(|%etc);
            # this may trigger cascading PDF::Object::Tree coercians
            # e.g. native Array to PDF::Object::Array
            $obj{ .key } = from-ast(.value) for $dict.pairs;
            $obj.setup-type($obj);
        }
        $obj;
    }

    has $!encoded;
    has $!decoded;

    method Filter is rw { self<Filter> }
    method DecodeParms is rw { self<DecodeParms> }
    method Length is rw { self<Length> }

    multi submethod BUILD( :$start!, :$end!, :$input!) {
        my $length = $end - $start + 1;
        $!encoded = $input.substr($start, $length );
    }

    multi submethod BUILD( :$!decoded!) {
    }

    multi submethod BUILD( :$!encoded!) {
    }

    multi submethod BUILD() {
    }

    method encoded {
        if $!decoded.defined && ! $!encoded.defined {
            $!encoded = $.encode( $!decoded );
        }
        self<Length> = $!encoded.chars;
        $!encoded;
    }

    method decoded {
        $!decoded //= $.decode( $!encoded )
            if $!encoded.defined;

        $!decoded;
    }

    method decode( Str $encoded = $.encoded ) {
        return $encoded unless self<Filter>:exists;
        PDF::Tools::Filter.decode( $encoded, :dict(self) );
    }

    method encode( Str $decoded = $.decoded) {
        return $decoded unless self<Filter>:exists;
        PDF::Tools::Filter.encode( $decoded, :dict(self) );
    }

    method content {
        my $encoded = $.encoded; # may update $.dict<Length>
        my $dict = to-ast-native self;
        :stream( %( $dict, :$encoded ));
    }
}
