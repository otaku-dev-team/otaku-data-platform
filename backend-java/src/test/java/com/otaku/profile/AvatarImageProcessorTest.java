package com.otaku.profile;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import javax.imageio.ImageIO;
import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 头像重编码（#378）：不连库、不连 Spring，只验「非方图 → 512×512 + 扩展名/可解码」。
 *
 * <p>为什么单独测：WebP 编码依赖原生库，平台差异是这一层最大的不确定性；
 * 如果编码器加载失败，{@link AvatarImageProcessor} 会退回 JPEG——两条路都必须可解码，
 * 不能只在「本机刚好有 WebP」时正确。
 */
class AvatarImageProcessorTest {

    private final AvatarImageProcessor processor = new AvatarImageProcessor();

    @Test
    @DisplayName("非方图居中裁方并缩放到 512×512，输出可被重新解码")
    void normalizesToSquare() throws Exception {
        byte[] source = png(800, 600);

        AvatarImageProcessor.Encoded encoded = processor.normalize(source, 512);

        assertThat(encoded).isNotNull();
        assertThat(encoded.extension()).isIn("webp", "jpg");
        assertThat(encoded.contentType()).isIn("image/webp", "image/jpeg");
        // 纯色测试图压缩后只有几百字节，不按大小卡；能解码 + 尺寸正确才是关键。
        assertThat(encoded.bytes().length).isGreaterThan(100);

        BufferedImage decoded = ImageIO.read(new ByteArrayInputStream(encoded.bytes()));
        assertThat(decoded).isNotNull();
        assertThat(decoded.getWidth()).isEqualTo(512);
        assertThat(decoded.getHeight()).isEqualTo(512);
    }

    @Test
    @DisplayName("小图也放大到目标边长（头像统一尺寸，客户端不用按源图判断）")
    void upscalesSmallImage() throws Exception {
        AvatarImageProcessor.Encoded encoded = processor.normalize(png(64, 64), 512);

        assertThat(encoded).isNotNull();
        BufferedImage decoded = ImageIO.read(new ByteArrayInputStream(encoded.bytes()));
        assertThat(decoded.getWidth()).isEqualTo(512);
        assertThat(decoded.getHeight()).isEqualTo(512);
    }

    @Test
    @DisplayName("WebP 编码器可用时必须真的产出 WebP（不能静默退回 JPEG）")
    void usesWebpWhenAvailable() throws Exception {
        org.junit.jupiter.api.Assumptions.assumeTrue(
                ImageIO.getImageWritersByMIMEType("image/webp").hasNext(),
                "当前平台没有 WebP 编码器，跳过（生产镜像 jammy x86_64 自带）");

        AvatarImageProcessor.Encoded encoded = processor.normalize(png(320, 240), 512);

        assertThat(encoded).isNotNull();
        // 2026-11-07 端到端实测踩过：只设 MODE_EXPLICIT + quality 会抛
        // 「No compression type set!」，随后静默退回 JPEG。这条用例专门钉住它。
        assertThat(encoded.extension()).isEqualTo("webp");
        assertThat(encoded.contentType()).isEqualTo("image/webp");
    }

    @Test
    @DisplayName("不是图片（或损坏）→ null，由服务层转 400")
    void rejectsNonImage() {
        assertThat(processor.normalize("<html>not an image</html>".getBytes(), 512)).isNull();
        assertThat(processor.normalize(new byte[]{1, 2, 3}, 512)).isNull();
        assertThat(processor.normalize(new byte[0], 512)).isNull();
    }

    private static byte[] png(int width, int height) throws Exception {
        BufferedImage image = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = image.createGraphics();
        try {
            g.setColor(new Color(30, 120, 200, 180));
            g.fillRect(0, 0, width, height);
            g.setColor(Color.WHITE);
            g.fillOval(width / 4, height / 4, width / 2, height / 2);
        } finally {
            g.dispose();
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ImageIO.write(image, "png", out);
        return out.toByteArray();
    }
}
