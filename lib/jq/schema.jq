# Checks a normalised object against a lib/schema/*.json table of key to allowed types. Used by the
# contract tests: it is what makes "the same keys and types on every board" a test, not a promise.

# Prints nothing for a good object, and one line per problem for a bad one.
def schema_problems($spec):
    . as $o
    | ($spec | keys) as $want
    | ($o | keys) as $got
    | (($want - $got) | map("missing key \(.)")),
      (($got - $want) | map("extra key \(.)")),
      ($want | map(select(. as $k | $o | has($k)))
             | map(select(. as $k | ($spec[$k] | split("|")) | index($o[$k] | type) | not))
             | map("key \(.) has type \($o[.] | type), wanted \($spec[.])"))
    | .[];
