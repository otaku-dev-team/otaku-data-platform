package com.otaku.profile;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import javax.imageio.IIOImage;
import javax.imageio.ImageIO;
import javax.imageio.ImageReader;
import javax.imageio.ImageWriteParam;
import javax.imageio.ImageWriter;
import javax.imageio.stream.ImageInputStream;
import javax.imageio.stream.ImageOutputStream;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Iterator;

/**
 * 头像图片处理（#378）：解码 → 居中裁方 → 缩放到固定边长 → 重编码。
 *
 * <p>为什么必须重编码而不是原样存：
 * <ol>
 *   <li><b>去 EXIF</b>：手机照片的 EXIF 里有 GPS 定位，原样存等于把用户位置一起发出去；</li>
 *   <li><b>防伪装文件</b>：只校验扩展名/MIME 挡不住「jpg 后缀的 HTML」，解码一次才知道是不是真图片；</li>
 *   <li><b>控体积</b>：统一 512×512，头像不会成为磁盘与带宽的无底洞。</li>
 * </ol>
 *
 * <p>编码优先 WebP（体积小、支持透明）；JDK 的 ImageIO 不认 WebP，靠
 * {@code webp-imageio} 的原生库。若原生库在当前平台加载失败，**退回 JPEG**——
 * 功能不该因为「少一个编码器」整体不可用，代价只是透明背景变白底（头像基本都有背景）。
 */
@Component
public class AvatarImageProcessor {

    private static final Logger log = LoggerFactory.getLogger(AvatarImageProcessor.class);

    /** 解码前的像素上限：挡住「1 万 × 1 万」的解压炸弹。512 头像不需要更大。 */
    private static final long MAX_SOURCE_PIXELS = 40_000_000L;
    /** 单边上限：超过直接判非法，避免 reader 先分配巨大缓冲。 */
    private static final int MAX_SOURCE_SIDE = 10_000;

    static {
        // 头像走内存，不需要 ImageIO 在磁盘上建临时缓存。
        ImageIO.setUseCache(false);
    }

    /** 处理结果；extension 不含点，contentType 是响应用的 MIME。 */
    public record Encoded(byte[] bytes, String extension, String contentType) {
    }

    /**
     * 归一化一张头像。无法解码返回 {@code null}（由调用方转 400）。
     *
     * @param input 原始字节
     * @param size  输出边长（正方形）
     */
    public Encoded normalize(byte[] input, int size) {
        if (input == null || input.length == 0) {
            return null;
        }
        BufferedImage source;
        try (ImageInputStream iis = ImageIO.createImageInputStream(new ByteArrayInputStream(input))) {
            if (iis == null) {
                return null;
            }
            Iterator<ImageReader> readers = ImageIO.getImageReaders(iis);
            if (!readers.hasNext()) {
                return null;
            }
            ImageReader reader = readers.next();
            try {
                reader.setInput(iis, true, true);
                int width = reader.getWidth(0);
                int height = reader.getHeight(0);
                if (width <= 0 || height <= 0 || width > MAX_SOURCE_SIDE || height > MAX_SOURCE_SIDE
                        || (long) width * height > MAX_SOURCE_PIXELS) {
                    return null;
                }
                source = reader.read(0);
            } finally {
                reader.dispose();
            }
        } catch (IOException | RuntimeException ex) {
            // 损坏的文件、伪装成图片的 HTML 都会走到这里；不是服务端故障。
            log.debug("头像解码失败: {}", ex.toString());
            return null;
        }
        if (source == null) {
            return null;
        }

        BufferedImage square = cropAndScale(source, size);
        if (hasWebpWriter()) {
            byte[] webp = encode(square, "webp", 0.85f);
            if (webp != null) {
                return new Encoded(webp, "webp", "image/webp");
            }
        }
        // 原生库缺失 / 编码失败：退回 JPEG（白底，不支持透明）。
        BufferedImage rgb = new BufferedImage(size, size, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = rgb.createGraphics();
        try {
            g.setColor(java.awt.Color.WHITE);
            g.fillRect(0, 0, size, size);
            g.drawImage(square, 0, 0, null);
        } finally {
            g.dispose();
        }
        byte[] jpeg = encode(rgb, "jpeg", 0.9f);
        return jpeg == null ? null : new Encoded(jpeg, "jpg", "image/jpeg");
    }

    /** 居中裁成正方形，再用双三次插值缩放到目标边长。 */
    private static BufferedImage cropAndScale(BufferedImage source, int size) {
        int side = Math.min(source.getWidth(), source.getHeight());
        int x = (source.getWidth() - side) / 2;
        int y = (source.getHeight() - side) / 2;

        BufferedImage out = new BufferedImage(size, size, BufferedImage.TYPE_INT_ARGB);
        Graphics2D g = out.createGraphics();
        try {
            g.setRenderingHint(RenderingHints.KEY_INTERPOLATION,
                    RenderingHints.VALUE_INTERPOLATION_BICUBIC);
            g.setRenderingHint(RenderingHints.KEY_RENDERING, RenderingHints.VALUE_RENDER_QUALITY);
            g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            g.drawImage(source, 0, 0, size, size, x, y, x + side, y + side, null);
        } finally {
            g.dispose();
        }
        return out;
    }

    private static boolean hasWebpWriter() {
        try {
            return ImageIO.getImageWritersByMIMEType("image/webp").hasNext();
        } catch (RuntimeException | LinkageError ex) {
            log.warn("WebP 编码器不可用，头像退回 JPEG：{}", ex.toString());
            return false;
        }
    }

    private static byte[] encode(BufferedImage image, String format, float quality) {
        Iterator<ImageWriter> writers = ImageIO.getImageWritersByFormatName(format);
        if (!writers.hasNext()) {
            return null;
        }
        ImageWriter writer = writers.next();
        try (ByteArrayOutputStream out = new ByteArrayOutputStream();
             ImageOutputStream ios = ImageIO.createImageOutputStream(out)) {
            writer.setOutput(ios);
            ImageWriteParam param = writer.getDefaultWriteParam();
            if (param.canWriteCompressed()) {
                param.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
                // WebP 的 writer 要求先选压缩类型再设质量；只设 MODE_EXPLICIT + quality
                // 会抛「No compression type set!」（2026-11-07 端到端实测）。
                String[] types = param.getCompressionTypes();
                if (types != null && types.length > 0) {
                    param.setCompressionType(types[0]);
                }
                param.setCompressionQuality(quality);
            }
            writer.write(null, new IIOImage(image, null, null), param);
            ios.flush();
            return out.toByteArray();
        } catch (IOException | RuntimeException ex) {
            log.warn("头像编码失败 format={}: {}", format, ex.toString());
            return null;
        } finally {
            writer.dispose();
        }
    }
}
