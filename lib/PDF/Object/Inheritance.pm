use v6;

role PDF::Object::Inheritance {

    #| find an heritable property
    proto method find-prop(|) {*}
    multi method find-prop($prop where self{$_}:exists) {
        temp self.reader.auto-deref = True;
        self{$prop}
    }
    multi method find-prop($prop where { self<Parent>:exists }) {
        temp self.reader.auto-deref = True;
        self<Parent>.find-prop($prop)
    }
    multi method find-prop($prop) is default {
    }

}
