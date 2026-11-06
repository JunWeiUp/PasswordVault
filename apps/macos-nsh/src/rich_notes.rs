//! Owner-bound attachment nodes keep their existing schema; render file names
//! through the official editor's native node-view plugin (no embedded browser).
use std::sync::Arc;
use nsh_core::prelude::*;
use nsh_base::rich_editor::{
    extensions::{Extension, RichExtensionRegistry},
    model::Node,
    state::{PluginSpec, ViewFactory},
    view::{NodeView, NodeViewCx},
};
struct AttachmentView;
impl NodeView for AttachmentView {
    fn create(&self, _cx: &NodeViewCx, node: &Node) -> AnyElement {
        let name = node.attrs().get("name").and_then(|v| v.as_str()).unwrap_or("附件");
        text(format!("📎 {name}")).p(px(10.0)).into_element()
    }
}
struct AttachmentViews;
impl PluginSpec for AttachmentViews {
    fn node_views(&self) -> Vec<(String, ViewFactory)> {
        let view: Arc<dyn NodeView> = Arc::new(AttachmentView);
        vec![("vaultAttachment".into(), Arc::new(view))]
    }
}
pub fn register(registry: &mut Registry) {
    registry.rich_extension("vaultAttachmentViews", || {
        Extension::new("vaultAttachmentViews").add_plugins(|_| vec![Arc::new(AttachmentViews)])
    });
}
