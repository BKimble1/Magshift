import Foundation

/// A fixed-capacity FIFO buffer.
///
/// Every buffer in the sensing pipeline is bounded. A scan can run for many
/// minutes at 50 Hz against a 60 Hz camera; an unbounded history would grow
/// without limit and eventually be terminated by the system. When the buffer is
/// full the oldest element is dropped.
struct BoundedBuffer<Element> {
    private var storage: [Element] = []
    /// Index of the logical first element within `storage`.
    private var head = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count >= capacity }

    var first: Element? { isEmpty ? nil : storage[head] }
    var last: Element? { storage.last }

    /// All elements, oldest first.
    var elements: [Element] {
        head == 0 ? storage : Array(storage[head...])
    }

    mutating func append(_ element: Element) {
        storage.append(element)
        if count > capacity {
            head += 1
        }
        // Compact when the dead prefix reaches the capacity, so `storage` never
        // grows beyond twice the capacity while still amortising the copy.
        if head >= capacity {
            storage.removeFirst(head)
            head = 0
        }
    }

    /// The most recent `k` elements, oldest first. Returns fewer if `count < k`.
    func suffix(_ k: Int) -> [Element] {
        guard k > 0 else { return [] }
        return Array(elements.suffix(k))
    }

    /// Element `k` positions back from the newest (`0` is the newest).
    func fromEnd(_ k: Int) -> Element? {
        let index = storage.count - 1 - k
        guard index >= head, index < storage.count else { return nil }
        return storage[index]
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

extension BoundedBuffer: Sequence {
    func makeIterator() -> Array<Element>.Iterator {
        elements.makeIterator()
    }
}
