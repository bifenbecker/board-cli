# Text renderings of the normalised objects. For people: --json is the stable interface.

def text_any:
    if type == "string" then .
    elif type == "array" then map(if type == "object" then tojson else tostring end) | join("\n")
    else tojson end;
