package com.otaku.usage;

import com.otaku.common.ApiException;
import com.otaku.usage.dto.UsageDtos.PingRequest;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.time.Clock;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.util.regex.Pattern;

/**
 * 客户端心跳的落库逻辑。
 *
 * <p>三件事，按顺序：校验形状 → 截断超长字段 → 写两张表。
 * 没有第四件——**这里刻意不做任何"识别"**：不反查 IP、不查 UA、不碰账号，
 * 所以即使这份数据泄露，能得到的也只是「有一台设备在某个时候开着 App」。
 */
@Service
public class UsageService {

    /**
     * UUID v4 的形状校验。
     *
     * <p>为什么必须校验：这是一个**公开的、不需要登录的**写接口。不校验的话，
     * 任何人都能往里写任意字符串——把电话号码、邮箱当 install_id 塞进来，
     * 这张"匿名表"就变成了个人信息表，而它的全部价值建立在「不含可识别信息」上。
     * 形状闸门不是防攻击（防不住），是**防它被当成任意字段的容器**。
     */
    private static final Pattern INSTALL_ID = Pattern.compile(
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");

    /** 与 V27 的列宽一致：app_version VARCHAR(32) / platform VARCHAR(16)。 */
    private static final int MAX_VERSION = 32;
    private static final int MAX_PLATFORM = 16;

    private final ClientInstallRepository repository;
    private final Clock clock;

    // 两个构造器时必须显式标注：Spring 4.3 起的「只有一个构造器就自动注入」不成立，
    // 不标会去找无参构造器，报 NoSuchMethodException: UsageService.<init>。
    @Autowired
    public UsageService(ClientInstallRepository repository) {
        this(repository, Clock.system(ZoneId.of("Asia/Shanghai")));
    }

    /** 单测用：注入固定时钟，"今天的日活"才可断言。 */
    UsageService(ClientInstallRepository repository, Clock clock) {
        this.repository = repository;
        this.clock = clock;
    }

    public void ping(PingRequest request) {
        if (request == null || request.installId() == null
                || !INSTALL_ID.matcher(request.installId()).matches()) {
            throw ApiException.badRequest("install_id 必须是 UUID v4 形式");
        }

        LocalDateTime now = LocalDateTime.now(clock);
        // 日期也按同一个时钟取：容器 TZ 是 Asia/Shanghai，但单测跑在别的时区，
        // 用 LocalDate.now() 会让「心跳落在哪一天」随测试机器漂移。
        LocalDate day = now.toLocalDate();

        repository.recordPing(request.installId().toLowerCase(),
                trim(request.appVersion(), MAX_VERSION),
                trim(request.platform(), MAX_PLATFORM),
                now, day);
    }

    /**
     * 截断而不是拒绝：版本号/平台是**附带信息**，写坏了不该让整次心跳失败——
     * 失败就等于这台设备今天不活跃，为了一个展示字段丢掉主线数据不划算。
     */
    private static String trim(String value, int max) {
        if (value == null || value.isBlank()) {
            return null;
        }
        String trimmed = value.strip();
        return trimmed.length() <= max ? trimmed : trimmed.substring(0, max);
    }
}
