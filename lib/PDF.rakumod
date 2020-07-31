use v6;

use PDF::COS::Dict;

#| this class represents the top level node in a PDF or FDF document,
#| the trailer dictionary
class PDF:ver<0.4.3>
    is PDF::COS::Dict {

    use PDF::IO::Serializer;
    use PDF::Reader;
    use PDF::Writer;
    use PDF::COS::Tie;
    use JSON::Fast;

    # use ISO_32000::Table_15-Entries_in_the_file_trailer_dictionary;
    # also does ISO_32000::Table_15-Entries_in_the_file_trailer_dictionary;

    has Int $.Size is entry;                              #| (Required; shall not be an indirect reference) greater than the highest object number defined in the file.

    use PDF::COS::Type::Encrypt;
    has PDF::COS::Type::Encrypt $.Encrypt is entry;       #| (Required if document is encrypted; PDF 1.1) The document’s encryption dictionary

    use PDF::COS::Type::Info;
    has PDF::COS::Type::Info $.Info is entry(:indirect);  #| (Optional; must be an indirect reference) The document’s information dictionary
    has Str @.ID is entry(:len(2));                       #| (Required if an Encrypt entry is present; optional otherwise; PDF 1.1) An array
                                                          #| of two byte-strings constituting a file identifier

    has Hash $.Root is entry( :indirect );                #| generic document root, as defined by subclassee, e.g.  PDF::Class, PDF::FDF
    has $.crypt is rw;
    has $!flush = False;

    has UInt $.Prev is entry; 

    #| open the input file-name or path
    method open($spec, Str :$type, |c) {
        my PDF::Reader $reader .= new;
        my \doc = self.new: :$reader;

        $reader.trailer = doc;
        $reader.open($spec, |c);
        with $type {
            die "PDF file has wrong type: " ~ $reader.type
                unless $reader.type eq $_;
        }
        doc.crypt = $_
            with $reader.crypt;
        doc;
    }

    method encrypt( Str :$owner-pass!, Str :$user-pass = '', :$EncryptMetadata = True, |c ) {

        die '.encrypt(:!EncryptMetadata, ...) is not yet supported'
            unless $EncryptMetadata;

        with $.reader {
            with .crypt {
                # the input document is already encrypted
                die "PDF is already encrypted. Need to be owner to re-encrypt"
                    unless .is-owner;
            }
        }

        self<Encrypt>:delete;
        $!flush = True;
        $!crypt = (require ::('PDF::IO::Crypt::PDF')).new: :doc(self), :$owner-pass, :$user-pass, |c;
    }

    method !is-indexed {
        with $.reader {
            ? (.input && .xrefs && .xrefs[0]);
        }
        else {
            False;
        }
    }

    method cb-finish {
	self.?cb-init
	    unless self<Root>:exists;
	self<Root>.?cb-finish;
    }
    #| perform an incremental save back to the opened input file, or write
    #| differences to the specified file
    method update(IO::Handle :$diffs, |c) {

        die "Newly encrypted PDF must be saved in full"
            if $!flush;

	die "PDF has not been opened for indexed read."
	    unless self!is-indexed;

        self.cb-finish;

	my $type = $.reader.type;
	self!generate-id( :$type );

        my PDF::IO::Serializer $serializer .= new( :$.reader, :$type );
        my Array $body = $serializer.body( :updates, |c );
	.crypt-ast('body', $body, :mode<encrypt>)
	    with $!crypt;

        if $diffs && $diffs.path ~~ m:i/'.json' $/ {
            # JSON output to a separate diffs file.
            my %ast = :cos{ :$body };
            $diffs.print: to-json(%ast);
            $diffs.close;
        }
        elsif ! +$body[0]<objects> {
            # no updates that need saving
        }
        else {
            self!incremental-save($body[0], :$diffs);
        }
    }

    method !incremental-save(Hash $body, :$diffs) {
        my Hash $trailer = $body<trailer><dict>;
	my UInt $prev = $trailer<Prev>.value;

        constant Preamble = "\n\n";
        my Numeric $offset = $.reader.input.codes + Preamble.codes;
        my $size = $.reader.size;
        my $compat = $.reader.compat;
        my PDF::Writer $writer .= new( :$offset, :$prev, :$size, :$compat  );
	my IO::Handle $fh;
        my Str $new-body = Preamble ~ $writer.write-body( $body, my @entries);

        do with $diffs {
	    $fh = $_ unless .path eq $.reader.file-name;
	}
	$fh //= do {
	    # in-place update. merge the updated entries in the index
	    # todo: we should be able to leave the input file open and append to it
	    $prev = $writer.prev;
	    my UInt $size = $writer.size;
	    $.reader.update( :@entries, :$prev, :$size);
	    $.Size = $size;
	    @entries = [];
            given $.reader.file-name {
                die "Incremental update of JSON files is not supported"
                    if  m:i/'.json' $/;
	        .IO.open(:a, :bin);
            }
	}

        $fh.write: $new-body.encode('latin-1');
        $fh.close;
    }

    method ast(|c) {
        self.cb-finish;
	my $type = $.reader.?type
            // self.?type
            // (self<Root><FDF>.defined ?? 'FDF' !! 'PDF');

	self!generate-id( :$type );
	my PDF::IO::Serializer $serializer .= new;
	$serializer.ast( self, :$type, :$!crypt, |c);
    }

    multi method save-as(IO() $iop,
                     Bool :$preserve = True,
                     Bool :$rebuild = False,
                     |c) {
	when $iop.extension.lc eq 'json' {
            # save as JSON
	    $iop.spurt( to-json( $.ast(|c) ));
	}
        when $preserve && !$rebuild && !$!flush && self!is-indexed {
            # copy the input PDF, then incrementally update it. This is faster
            # and plays better with digitally signed documents.
            my $diffs = $iop.open(:a, :bin);
            given $.reader.file-name {
	        .IO.copy( $iop )
                    unless $iop.path eq $_;
            }
	    $.update( :$diffs, |c);
	}
	default {
            # full save
	    my $ioh = $iop.open(:w, :bin);
	    $.save-as($ioh, :$rebuild, |c);
	}
    }

    multi method save-as(IO::Handle $ioh, |c) is default {
        my $eager := ! $!flush;
        my $ast = $.ast(:$eager, |c);
        my PDF::Writer $writer .= new: :$ast;
        $ioh.write: $writer.Blob;
        $ioh.close;
    }

    #| stringify to the serialized PDF
    method Str(|c) {
        my PDF::Writer $writer .= new: |c;
	$writer.write( $.ast )
    }

    # permissions check, e.g: $doc.permitted( PermissionsFlag::Modify )
    method permitted(UInt $flag --> Bool) is DEPRECATED('please use PDF::Class.permitted') {

        return True
            if $!crypt.?is-owner;

        with self.Encrypt {
            .permitted($flag);
        }
        else {
            True;
        }
    }

    method Blob(|c) returns Blob {
	self.Str(|c).encode: "latin-1";
    }

    #| Generate a new document ID.
    method !generate-id(Str :$type = 'PDF') {

	# From [PDF 32000 Section 14.4 File Identifiers:
	#   "File identifiers shall be defined by the optional ID entry in a PDF file’s trailer dictionary.
	# The ID entry is optional but should be used. The value of this entry shall be an array of two
	# byte strings. The first byte string shall be a permanent identifier based on the contents of the
	# file at the time it was originally created and shall not change when the file is incrementally
	# updated. The second byte string shall be a changing identifier based on the file’s contents at
	# the time it was last updated. When a file is first written, both identifiers shall be set to the
	# same value. If both identifiers match when a file reference is resolved, it is very likely that
	# the correct and unchanged file has been found. If only the first identifier matches, a different
	# version of the correct file has been found.
	#
	# This section also includes a weird and expensive solution for generating the ID.
	# Contrary to this, just generate a random identifier.

	my $obj = $type eq 'FDF' ?? self<Root><FDF> !! self;
	my Str $hex-string = Buf.new((^256).pick xx 16).decode("latin-1");
	my \new-id = PDF::COS.coerce: :$hex-string;

	with $obj<ID> {
	    .[1] = new-id; # Update modification ID
	}
	else {
	    $_ = [ new-id, new-id ]; # Initialize creation and modification IDs
	}
    }
}
