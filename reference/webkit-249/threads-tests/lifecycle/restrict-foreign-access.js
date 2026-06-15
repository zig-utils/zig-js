//@ requireOptions("--useJSThreads=1")
// SPEC-api 5.7: Thread.restrict wires the foreign-thread access choke point
// through ordinary property access, mutation, deletion, and enumeration.
load("../resources/assert.js", "caller relative");

const restricted = Thread.restrict({ secret: 1, toDelete: 2 });

// Owner access keeps working.
shouldBe(restricted.secret, 1);

// Foreign read.
shouldBe(new Thread(o => {
    try {
        o.secret;
        return "no-throw";
    } catch (e) {
        return e.name;
    }
}, restricted).join(), "ConcurrentAccessError");

// Foreign write.
shouldBe(new Thread(o => {
    try {
        o.secret = 99;
        return "no-throw";
    } catch (e) {
        return e.name;
    }
}, restricted).join(), "ConcurrentAccessError");
shouldBe(restricted.secret, 1, "foreign write must not land");

// Foreign property add.
shouldThrow(ConcurrentAccessError, () => {
    const error = new Thread(o => {
        try {
            o.fresh = 1;
            return null;
        } catch (e) {
            return e;
        }
    }, restricted).join();
    if (error)
        throw error;
});
shouldBeFalse("fresh" in restricted);

// Foreign delete.
shouldBe(new Thread(o => {
    try {
        delete o.toDelete;
        return "no-throw";
    } catch (e) {
        return e.name;
    }
}, restricted).join(), "ConcurrentAccessError");
shouldBeTrue("toDelete" in restricted);

// Foreign enumeration (snapshot of property names is a proxyable op).
shouldBe(new Thread(o => {
    try {
        Object.keys(o);
        return "no-throw";
    } catch (e) {
        return e.name;
    }
}, restricted).join(), "ConcurrentAccessError");
