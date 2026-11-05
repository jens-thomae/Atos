//! Gives a widget that has no accessibility node of its own (libcosmic's text
//! input and tab bar at this revision) a named one. Pure delegation otherwise;
//! modelled on libcosmic's `id_container`.

use cosmic::iced::core::event::Event;
use cosmic::iced::core::widget::{Id, Operation, Tree};
use cosmic::iced::core::{
    Clipboard, Element, Layout, Length, Rectangle, Shell, Size, Vector, Widget, layout, mouse,
    overlay, renderer,
};
use iced_accessibility::accesskit::{Action, Node, Rect};
use iced_accessibility::A11yTree;

pub use iced_accessibility::accesskit::Role;

/// Wraps `content` in an accessibility node with the given role and name.
pub fn named<'a, Message: 'a, Theme: 'a, Renderer: cosmic::iced::core::Renderer + 'a>(
    content: impl Into<Element<'a, Message, Theme, Renderer>>,
    role: Role,
    name: &'static str,
) -> Named<'a, Message, Theme, Renderer> {
    Named {
        content: content.into(),
        role,
        name,
    }
}

pub struct Named<'a, Message, Theme, Renderer> {
    content: Element<'a, Message, Theme, Renderer>,
    role: Role,
    name: &'static str,
}

impl<Message, Theme, Renderer> Widget<Message, Theme, Renderer>
    for Named<'_, Message, Theme, Renderer>
where
    Renderer: cosmic::iced::core::Renderer,
{
    fn children(&self) -> Vec<Tree> {
        vec![Tree::new(&self.content)]
    }

    fn diff(&mut self, tree: &mut Tree) {
        tree.diff_children(std::slice::from_mut(&mut self.content));
    }

    fn size(&self) -> Size<Length> {
        self.content.as_widget().size()
    }

    fn layout(
        &mut self,
        tree: &mut Tree,
        renderer: &Renderer,
        limits: &layout::Limits,
    ) -> layout::Node {
        let node = self
            .content
            .as_widget_mut()
            .layout(&mut tree.children[0], renderer, limits);
        let size = node.size();
        layout::Node::with_children(size, vec![node])
    }

    fn operate(
        &mut self,
        tree: &mut Tree,
        layout: Layout<'_>,
        renderer: &Renderer,
        operation: &mut dyn Operation,
    ) {
        self.content.as_widget_mut().operate(
            &mut tree.children[0],
            layout
                .children()
                .next()
                .unwrap()
                .with_virtual_offset(layout.virtual_offset()),
            renderer,
            operation,
        );
    }

    fn update(
        &mut self,
        tree: &mut Tree,
        event: &Event,
        layout: Layout<'_>,
        cursor_position: mouse::Cursor,
        renderer: &Renderer,
        clipboard: &mut dyn Clipboard,
        shell: &mut Shell<'_, Message>,
        viewport: &Rectangle,
    ) {
        self.content.as_widget_mut().update(
            &mut tree.children[0],
            event,
            layout
                .children()
                .next()
                .unwrap()
                .with_virtual_offset(layout.virtual_offset()),
            cursor_position,
            renderer,
            clipboard,
            shell,
            viewport,
        );
    }

    fn mouse_interaction(
        &self,
        tree: &Tree,
        layout: Layout<'_>,
        cursor_position: mouse::Cursor,
        viewport: &Rectangle,
        renderer: &Renderer,
    ) -> mouse::Interaction {
        self.content.as_widget().mouse_interaction(
            &tree.children[0],
            layout
                .children()
                .next()
                .unwrap()
                .with_virtual_offset(layout.virtual_offset()),
            cursor_position,
            viewport,
            renderer,
        )
    }

    fn draw(
        &self,
        tree: &Tree,
        renderer: &mut Renderer,
        theme: &Theme,
        style: &renderer::Style,
        layout: Layout<'_>,
        cursor_position: mouse::Cursor,
        viewport: &Rectangle,
    ) {
        self.content.as_widget().draw(
            &tree.children[0],
            renderer,
            theme,
            style,
            layout
                .children()
                .next()
                .unwrap()
                .with_virtual_offset(layout.virtual_offset()),
            cursor_position,
            viewport,
        );
    }

    fn overlay<'b>(
        &'b mut self,
        tree: &'b mut Tree,
        layout: Layout<'b>,
        renderer: &Renderer,
        viewport: &Rectangle,
        translation: Vector,
    ) -> Option<overlay::Element<'b, Message, Theme, Renderer>> {
        self.content.as_widget_mut().overlay(
            &mut tree.children[0],
            layout
                .children()
                .next()
                .unwrap()
                .with_virtual_offset(layout.virtual_offset()),
            renderer,
            viewport,
            translation,
        )
    }

    fn a11y_nodes(
        &self,
        layout: Layout<'_>,
        state: &Tree,
        cursor: mouse::Cursor,
    ) -> A11yTree {
        let Rectangle {
            x,
            y,
            width,
            height,
        } = layout.bounds();
        let mut node = Node::new(self.role);
        node.set_bounds(Rect::new(
            x as f64,
            y as f64,
            (x + width) as f64,
            (y + height) as f64,
        ));
        node.set_label(self.name);
        if self.role == Role::TextInput {
            node.add_action(Action::Focus);
        }
        let child = self.content.as_widget().a11y_nodes(
            layout
                .children()
                .next()
                .unwrap()
                .with_virtual_offset(layout.virtual_offset()),
            &state.children[0],
            cursor,
        );
        A11yTree::node_with_child_tree(
            iced_accessibility::A11yNode::new(node, Id::new(self.name)),
            child,
        )
    }
}

impl<'a, Message: 'a, Theme: 'a, Renderer: cosmic::iced::core::Renderer + 'a>
    From<Named<'a, Message, Theme, Renderer>> for Element<'a, Message, Theme, Renderer>
{
    fn from(n: Named<'a, Message, Theme, Renderer>) -> Self {
        Element::new(n)
    }
}
