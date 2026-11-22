const HashNode = struct {
    next: *HashNode,
    key: []u8,
    value: []u8,
};

const HashTable = struct {
    table: []HashNode,
};
