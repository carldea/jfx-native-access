///usr/bin/env jbang "$0" "$@" ; exit $?
//DEPS org.openjfx:javafx-controls:26.0.1:mac-aarch64

//RUNTIME_OPTIONS --enable-native-access=ALL-UNNAMED,javafx.graphics
//RUNTIME_OPTIONS --add-opens javafx.graphics/com.sun.glass.ui=ALL-UNNAMED

/*

Copyright 2026 Carl Dea

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://apache.org

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and limitations under the License.
*/
package com.prototype;

import javafx.animation.AnimationTimer;
import javafx.application.Application;
import javafx.application.Platform;
import javafx.geometry.Bounds;
import javafx.scene.Scene;
import javafx.scene.control.Button;
import javafx.scene.control.Label;
import javafx.scene.control.CheckBox;
import javafx.scene.control.ComboBox;
import javafx.scene.control.Slider;
import javafx.scene.control.SplitPane;
import javafx.scene.layout.Pane;
import javafx.scene.layout.VBox;
import javafx.scene.text.Text;
import javafx.stage.Stage;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.io.IOException;
import java.io.InputStream;
import java.lang.invoke.MethodHandle;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.Paths;

public class NativeMetalApp extends Application {

    private MetalRenderer renderer;

    private Pane rightMetalPane;
    private AnimationTimer frameTimer;
    // Variables to keep track of drag baselines
    private double lastMouseX;
    private double lastMouseY;
    // 0 = Normal Rounded, 1 = Irregular Ellipse (tied to the clip CheckBox)
    private int activeClipMode = 0;

    @Override
    public void init() throws Exception {
        renderer = new MetalRenderer(locateDylib());
    }

    /**
     * Uses ./librenderer.dylib when present (jbang / dev runs), otherwise extracts
     * the copy bundled at the root of the jar to a temp file.
     */
    private static Path locateDylib() throws IOException {
        Path local = Paths.get("librenderer.dylib").toAbsolutePath();
        if (Files.exists(local)) {
            return local;
        }
        try (InputStream in = NativeMetalApp.class.getResourceAsStream("/librenderer.dylib")) {
            if (in == null) {
                throw new IOException("librenderer.dylib not found in working directory or on classpath");
            }
            Path tmp = Files.createTempFile("librenderer", ".dylib");
            tmp.toFile().deleteOnExit();
            Files.copy(in, tmp, StandardCopyOption.REPLACE_EXISTING);
            return tmp;
        }
    }

    @Override
    public void stop() throws Exception {
        destroyRenderer();
    }

    /** Stops the frame loop and frees the native renderer while the parent NSWindow still exists. */
    private void destroyRenderer() {
        if (frameTimer != null) {
            frameTimer.stop();
        }
        if (renderer != null) {
            renderer.close();
        }
    }

    @Override
    public void start(Stage primaryStage) {
        primaryStage.setTitle("JavaFX 25 FFM Metal Overlay");

        VBox leftPane = new VBox(15);
        leftPane.setStyle("-fx-padding: 20px;");
        leftPane.setMinWidth(250);
        Text statusText = new Text("Native Surface Status: Unbound");
        Button triggerBtn = new Button("Interact");
        CheckBox clipToggle = new CheckBox("Enable Irregular Clip Path");
        clipToggle.setOnAction(e -> {
            activeClipMode = clipToggle.isSelected() ? 1 : 0;
            syncNativeOverlayBounds();
        });
        // Build and style the JavaFX Slider control
        Slider opacitySlider = new Slider(0.0, 1.0, 0.4); // Min 0.0, Max 1.0, Default 0.4
        opacitySlider.setShowTickMarks(true);
        opacitySlider.setShowTickLabels(true);
        opacitySlider.setMajorTickUnit(0.25);
        opacitySlider.setBlockIncrement(0.05);

        Label opacityLabel = new Label("Metal Layer Opacity: 40%");
        opacityLabel.setStyle("-fx-font-weight: bold;");

        // Reactive listener to fire native pipeline adjustments instantly
        opacitySlider.valueProperty().addListener((observable, oldValue, newValue) -> {
            float targetAlpha = newValue.floatValue();
            opacityLabel.setText(String.format("Metal Layer Opacity: %d%%", (int)(targetAlpha * 100)));
            renderer.setAlpha(targetAlpha);
        });

        // Select 2D or 3D display mode
        ComboBox<String> viewModeCombo = new ComboBox<>();
        viewModeCombo.getItems().addAll("2D Stretching Triangle", "3D Interactive Prism");
        viewModeCombo.getSelectionModel().selectFirst();
        viewModeCombo.setOnAction(e ->
            renderer.setRenderMode(viewModeCombo.getSelectionModel().getSelectedIndex()));

        leftPane.getChildren().addAll(statusText, triggerBtn, clipToggle, opacitySlider, viewModeCombo);

        // Right view placeholder pane instead of a SwingNode
        rightMetalPane = new Pane();

        // Give the pane a loud, high-contrast gradient background via CSS
        rightMetalPane.setStyle("-fx-background-color: linear-gradient(to bottom right, #ff7e5f, #feb47b, #2f80ed);");

        // Drop a high-contrast Label inside it to verify sharpness/clipping
        Label testPatternLabel = new Label("JAVAFX CONTENT UNDERNEATH\nGPU METAL LAYER ACTIVE");
        testPatternLabel.setStyle("-fx-font-size: 20px; -fx-text-fill: white; -fx-font-weight: bold; -fx-alignment: center;");
        testPatternLabel.setWrapText(true);
        rightMetalPane.getChildren().add(testPatternLabel);

        // Mouse drag rotates the 3D shape
        rightMetalPane.setOnMousePressed(e -> {
            lastMouseX = e.getX();
            lastMouseY = e.getY();
        });

        rightMetalPane.setOnMouseDragged(e -> {
            float deltaX = (float) (e.getX() - lastMouseX);
            float deltaY = (float) (e.getY() - lastMouseY);
            lastMouseX = e.getX();
            lastMouseY = e.getY();
            renderer.rotate(deltaX, deltaY);
        });

        SplitPane root = new SplitPane();
        root.getItems().addAll(leftPane, rightMetalPane);

        primaryStage.setScene(new Scene(root, 1024, 768));
        primaryStage.show();

        Platform.runLater(() -> {
            root.setDividerPositions(0.3f);
            long nsWindowHandle = getGlassWindowHandle();
            if (nsWindowHandle != 0 && renderer.attach(nsWindowHandle)) {
                statusText.setText("Metal Overlay Attached!");
            }
        });

        // Tear down before Glass releases the native window (stop() runs too late).
        primaryStage.setOnHiding(e -> destroyRenderer());

        // Loop handles layout syncing and animation on the frame pulse
        frameTimer = new AnimationTimer() {
            @Override
            public void handle(long now) {
                if (renderer.isAttached()) {
                    syncNativeOverlayBounds();
                    renderer.renderFrame();
                }
            }
        };
        frameTimer.start();
    }

    private void syncNativeOverlayBounds() {
        Scene scene = rightMetalPane.getScene();
        if (scene == null) return;

        Bounds bounds = rightMetalPane.localToScene(rightMetalPane.getBoundsInLocal());
        renderer.updateBounds(bounds.getMinX(), bounds.getMinY(), bounds.getWidth(), bounds.getHeight(), activeClipMode);
    }

    private long getGlassWindowHandle() {
        try {
            Class<?> windowClass = Class.forName("com.sun.glass.ui.Window");
            java.lang.reflect.Method getWindows = windowClass.getMethod("getWindows");
            java.util.List<?> windows = (java.util.List<?>) getWindows.invoke(null);

            if (!windows.isEmpty()) {
                Object mainGlassWindow = windows.get(0);
                java.lang.reflect.Method getNativeWindow = mainGlassWindow.getClass().getMethod("getNativeWindow");
                return (long) getNativeWindow.invoke(mainGlassWindow);
            }
        } catch (Exception e) {
            System.err.println("Could not resolve native Glass handle.");
            e.printStackTrace();
        }
        return 0;
    }

    public static void main(String[] args) {
        launch(args);
    }

    /**
     * Entry point for the full (fat) jar. The JVM refuses to start a main class that extends
     * {@link Application} when JavaFX is on the classpath instead of the module path
     * ("JavaFX runtime components are missing"), so the fat jar starts from this class instead.
     */
    public static final class Launcher {
        public static void main(String[] args) {
            Application.launch(NativeMetalApp.class, args);
        }
    }

    /**
     * Java facade over librenderer.dylib. All FFM bindings and native calls live here.
     * Calls are no-ops until {@link #attach(long)} succeeds and again after {@link #close()}.
     * Native failures are logged, never thrown to the UI.
     */
    private static final class MetalRenderer implements AutoCloseable {

        private final MethodHandle initMetalFunc;
        private final MethodHandle updateBoundsFunc;
        private final MethodHandle renderFrameFunc;
        private final MethodHandle setAlphaFunc;
        private final MethodHandle setRenderModeFunc;
        private final MethodHandle updateRotationFunc;
        private final MethodHandle destroyMetalFunc;

        private MemorySegment ctx = MemorySegment.NULL;

        MetalRenderer(Path dylib) {
            SymbolLookup lookup = SymbolLookup.libraryLookup(dylib, Arena.global());
            Linker linker = Linker.nativeLinker();

            initMetalFunc = bind(lookup, linker, "init_metal_renderer",
                FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS));

            updateBoundsFunc = bind(lookup, linker, "update_renderer_bounds",
                FunctionDescriptor.ofVoid(
                    ValueLayout.ADDRESS,     // renderer context pointer
                    ValueLayout.JAVA_DOUBLE, // X
                    ValueLayout.JAVA_DOUBLE, // Y
                    ValueLayout.JAVA_DOUBLE, // Width
                    ValueLayout.JAVA_DOUBLE, // Height
                    ValueLayout.JAVA_INT     // clipMode flag (0 = Normal Rounded, 1 = Irregular Ellipse)
                ));

            renderFrameFunc = bind(lookup, linker, "render_frame",
                FunctionDescriptor.ofVoid(ValueLayout.ADDRESS));

            setAlphaFunc = bind(lookup, linker, "set_renderer_alpha",
                FunctionDescriptor.ofVoid(
                    ValueLayout.ADDRESS,   // renderer context pointer
                    ValueLayout.JAVA_FLOAT // alpha value
                ));

            setRenderModeFunc = bind(lookup, linker, "set_render_mode",
                FunctionDescriptor.ofVoid(ValueLayout.ADDRESS, ValueLayout.JAVA_INT));

            updateRotationFunc = bind(lookup, linker, "update_rotation",
                FunctionDescriptor.ofVoid(ValueLayout.ADDRESS, ValueLayout.JAVA_FLOAT, ValueLayout.JAVA_FLOAT));

            destroyMetalFunc = bind(lookup, linker, "destroy_metal_renderer",
                FunctionDescriptor.ofVoid(ValueLayout.ADDRESS));
        }

        private static MethodHandle bind(SymbolLookup lookup, Linker linker, String symbol, FunctionDescriptor descriptor) {
            MemorySegment address = lookup.find(symbol)
                .orElseThrow(() -> new IllegalStateException("Native symbol not found: " + symbol));
            return linker.downcallHandle(address, descriptor);
        }

        /** Creates the Metal overlay inside the given NSWindow. Returns true on success. */
        boolean attach(long nsWindowHandle) {
            if (isAttached()) return true;
            try {
                ctx = (MemorySegment) initMetalFunc.invokeExact(MemorySegment.ofAddress(nsWindowHandle));
            } catch (Throwable t) {
                t.printStackTrace();
                ctx = MemorySegment.NULL;
            }
            return isAttached();
        }

        boolean isAttached() {
            return ctx.address() != 0;
        }

        void updateBounds(double x, double y, double width, double height, int clipMode) {
            if (!isAttached()) return;
            try {
                updateBoundsFunc.invokeExact(ctx, x, y, width, height, clipMode);
            } catch (Throwable t) {
                t.printStackTrace();
            }
        }

        void renderFrame() {
            if (!isAttached()) return;
            try {
                renderFrameFunc.invokeExact(ctx);
            } catch (Throwable t) {
                t.printStackTrace();
            }
        }

        void setAlpha(float alpha) {
            if (!isAttached()) return;
            try {
                setAlphaFunc.invokeExact(ctx, alpha);
            } catch (Throwable t) {
                t.printStackTrace();
            }
        }

        void setRenderMode(int mode) {
            if (!isAttached()) return;
            try {
                setRenderModeFunc.invokeExact(ctx, mode);
            } catch (Throwable t) {
                t.printStackTrace();
            }
        }

        void rotate(float deltaX, float deltaY) {
            if (!isAttached()) return;
            try {
                updateRotationFunc.invokeExact(ctx, deltaX, deltaY);
            } catch (Throwable t) {
                t.printStackTrace();
            }
        }

        /** Frees the native renderer. Safe to call more than once. */
        @Override
        public void close() {
            if (!isAttached()) return;
            MemorySegment old = ctx;
            ctx = MemorySegment.NULL;
            try {
                destroyMetalFunc.invokeExact(old);
            } catch (Throwable t) {
                t.printStackTrace();
            }
        }
    }
}
