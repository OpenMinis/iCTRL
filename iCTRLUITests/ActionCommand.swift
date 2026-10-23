import Foundation

struct ActionCommand {
    let name: String
    var x: Double?
    var y: Double?
    var direction: String?
    var distance: Double?
    var text: String?
    var duration: Double?
    var elementId: String?
    var elementType: String?
    var bundleId: String?
    var fast: Bool?
    var dragPathParams: [String: JSONValue]?
    var fromX: Double?
    var fromY: Double?
    var toX: Double?
    var toY: Double?
    var scale: Double?
    var velocity: String?
    var matchMode: String?
    var ref: String?
    var fromRef: String?
    var toRef: String?
    var submit: Bool?
    var clear: Bool?
    var country: String?
    var url: String?
    // page_source scoping
    var maxDepth: Int?
    var maxElements: Int?
    var filterType: String?
    var filterLabel: String?
    var filterText: String?
    var includeOverlays: Bool?
    var visibleOnly: Bool?
    var maxChildren: Int?
    // screenshot encoding
    var format: String?
    var quality: Double?
    // post-action settle check
    var settle: Bool?
    var pages: Int?
    var minLength: Int?
    var fresh: Bool?
    var enhanced: Bool?
    var source: String?
    var settleTimeout: Double?

    init(method: String, params: [String: JSONValue]?) {
        self.name = method
        self.x = params?["x"]?.doubleValue
        self.y = params?["y"]?.doubleValue
        self.direction = params?["direction"]?.stringValue
        self.distance = params?["distance"]?.doubleValue
        self.text = params?["text"]?.stringValue
        self.duration = params?["duration"]?.doubleValue
        self.elementId = params?["element_id"]?.stringValue
        self.elementType = params?["element_type"]?.stringValue
        self.bundleId = params?["bundle_id"]?.stringValue
        self.fast = params?["fast"]?.boolValue
        self.dragPathParams = method == "drag" && params?["points"] != nil ? params : nil
        self.fromX = params?["from_x"]?.doubleValue
        self.fromY = params?["from_y"]?.doubleValue
        self.toX = params?["to_x"]?.doubleValue
        self.toY = params?["to_y"]?.doubleValue
        self.scale = params?["scale"]?.doubleValue
        self.velocity = params?["velocity"]?.stringValue
        self.matchMode = params?["match"]?.stringValue
        self.ref = params?["ref"]?.stringValue
        self.fromRef = params?["from_ref"]?.stringValue
        self.toRef = params?["to_ref"]?.stringValue
        self.submit = params?["submit"]?.boolValue
        self.clear = params?["clear"]?.boolValue
        self.format = params?["format"]?.stringValue
        self.quality = params?["quality"]?.doubleValue
        self.country = params?["country"]?.stringValue
        self.url = params?["url"]?.stringValue
        self.settle = params?["settle"]?.boolValue
        self.pages = params?["pages"]?.intValue
        self.minLength = params?["min_length"]?.intValue
        self.fresh = params?["fresh"]?.boolValue
        self.enhanced = params?["enhanced"]?.boolValue
        self.source = params?["source"]?.stringValue
        self.settleTimeout = params?["settle_timeout"]?.doubleValue

        self.maxDepth = params?["max_depth"]?.intValue
        self.maxElements = params?["max_elements"]?.intValue
        self.visibleOnly = params?["visible_only"]?.boolValue
        self.maxChildren = params?["max_children"]?.intValue
        // filter can be a nested object {type,label,text} or top-level keys.
        let filter = params?["filter"]?.objectValue
        self.filterType = filter?["type"]?.stringValue ?? params?["filter_type"]?.stringValue
        self.filterLabel = filter?["label"]?.stringValue ?? params?["filter_label"]?.stringValue
        self.filterText = filter?["text"]?.stringValue ?? params?["filter_text"]?.stringValue
        self.includeOverlays = params?["include_overlays"]?.boolValue
    }
}
