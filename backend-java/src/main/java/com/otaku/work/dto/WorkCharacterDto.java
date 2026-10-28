package com.otaku.work.dto;

/**
 * 一条角色与声优记录（契约 {@code WorkCharacter}）。形状与 {@code docs/openapi.yaml} 对齐，
 * 让后端能在详情里返回 {@code characters} 数组。
 *
 * <p>数据接线（从库里拉角色/声优并装配）归后端档 B 实现（#255）；
 * 本 DTO 此刻只在 {@code WorkDto} 里以 {@code null} 占位，契约侧 {@code nullable: true} 也允许为空。
 */
public record WorkCharacterDto(
        String name,
        String actor,
        String characterType,
        String personId
) {
}
