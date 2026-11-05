//! Pass-through wrapper that exposes its content as one accessibility node with a
//! role and a name. libcosmic's text input and tab bar publish no AT-SPI node of
//! their own, so every new control that lacks one is wrapped in this.

use cosmic::Element;
use cosmic::iced::advanced::widget::{Operation, Tree};
use cosmic::iced::advanced::{Clipboard, Layout, Shell, Widget, layout, mouse, overlay, renderer};
use cosmic::iced::{Event, Length, Rectangle, Size, Vector};
use iced_accessibility::accesskit::{Node, Rect, Role};
use iced_accessibility::{A11yId, A11yNode, A11yTree, Id};

pub struct Labeled<'a, Message> {
    content: Element<'a, Message>,
    role: Role,
    label: &'a str,
}

pub fn labeled<'a, Message>(
    role: Role,
    label: &'a str,
    content: impl Into<Element<'a, Message>>,
) -> Labeled<'a, Message> {
    Labeled {
        content: content.into(),
        role,
        label,
    }
}

impl<Message> Widget<Message, cosmic::Theme, cosmic::Renderer> for Labeled<'_, Message> {
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
        renderer: &cosmic::Renderer,
        limits: &layout::Limits,
    ) -> layout::Node {
        let node = self
            .content
            .as_widget_mut()
            .layout(&mut tree.children[0], renderer, limits);
        layout::Node::with_children(node.size(), vec![node])
    }

    fn operate(
        &mut self,
        tree: &mut Tree,
        layout: Layout<'_>,
        renderer: &cosmic::Renderer,
        operation: &mut dyn Operation,
    ) {
        self.content.as_widget_mut().operate(
            &mut tree.children[0],
            layout.children().next().unwrap(),
            renderer,
            operation,
        );
    }

    fn update(
        &mut self,
        tree: &mut Tree,
        event: &Event,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        renderer: &cosmic::Renderer,
        clipboard: &mut dyn Clipboard,
        shell: &mut Shell<'_, Message>,
        viewport: &Rectangle,
    ) {
        self.content.as_widget_mut().update(
            &mut tree.children[0],
            event,
            layout.children().next().unwrap(),
            cursor,
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
        cursor: mouse::Cursor,
        viewport: &Rectangle,
        renderer: &cosmic::Renderer,
    ) -> mouse::Interaction {
        self.content.as_widget().mouse_interaction(
            &tree.children[0],
            layout.children().next().unwrap(),
            cursor,
            viewport,
            renderer,
        )
    }

    fn draw(
        &self,
        tree: &Tree,
        renderer: &mut cosmic::Renderer,
        theme: &cosmic::Theme,
        style: &renderer::Style,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        viewport: &Rectangle,
    ) {
        self.content.as_widget().draw(
            &tree.children[0],
            renderer,
            theme,
            style,
            layout.children().next().unwrap(),
            cursor,
            viewport,
        );
    }

    fn overlay<'b>(
        &'b mut self,
        tree: &'b mut Tree,
        layout: Layout<'b>,
        renderer: &cosmic::Renderer,
        viewport: &Rectangle,
        translation: Vector,
    ) -> Option<overlay::Element<'b, Message, cosmic::Theme, cosmic::Renderer>> {
        self.content.as_widget_mut().overlay(
            &mut tree.children[0],
            layout.children().next().unwrap(),
            renderer,
            viewport,
            translation,
        )
    }

    fn a11y_nodes(&self, layout: Layout<'_>, tree: &Tree, cursor: mouse::Cursor) -> A11yTree {
        let b = layout.bounds();
        let mut node = Node::new(self.role);
        node.set_bounds(Rect::new(
            b.x as f64,
            b.y as f64,
            (b.x + b.width) as f64,
            (b.y + b.height) as f64,
        ));
        node.set_label(self.label);
        let id = A11yId::from(Id::new(format!("labeled-{}", self.label)));
        let child = self.content.as_widget().a11y_nodes(
            layout.children().next().unwrap(),
            &tree.children[0],
            cursor,
        );
        A11yTree::node_with_child_tree(A11yNode::new(node, id), child)
    }
}

impl<'a, Message: 'a> From<Labeled<'a, Message>> for Element<'a, Message> {
    fn from(w: Labeled<'a, Message>) -> Self {
        Element::new(w)
    }
}
