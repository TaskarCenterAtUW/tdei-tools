/** @format */

// ==UserScript==
// @name         Azure DevOps - Copy Work Item Link
// @namespace    https://dev.azure.com/
// @version      1.3.0
// @description  Copies the current Azure DevOps work item as a paste-able rich-text link.
// @match        https://dev.azure.com/*
// @grant        GM_setClipboard
// @grant        GM_registerMenuCommand
// @run-at       document-idle
// ==/UserScript==

(function () {
    "use strict";

    const BUTTON_ID = "vm-copy-ado-work-item-link";
    const DEFAULT_BUTTON_TEXT = "Copy work item link";

    const REQUEST_TIMEOUT_MS = 10_000;

    let statusTimer = null;
    let isCopying = false;

    /**
     * Reads the organization and project from the first two URL segments.
     *
     * Expected base URL:
     * https://dev.azure.com/{organization}/{project}/...
     */
    function getOrganizationAndProject() {
        const pathSegments = window.location.pathname
            .split("/")
            .filter(Boolean);

        if (pathSegments.length < 2) {
            return null;
        }

        try {
            return {
                organization: decodeURIComponent(pathSegments[0]),
                project: decodeURIComponent(pathSegments[1]),
            };
        } catch (error) {
            console.error(
                "[Azure DevOps Copy Work Item Link] " +
                    "Unable to parse organization or project.",
                error
            );

            return null;
        }
    }

    /**
     * Gets the work item ID from either:
     *
     * 1. A standard work-item URL:
     *    /_workitems/edit/4034
     *
     * 2. A taskboard or sprint URL:
     *    ?workitem=3793
     *
     * 3. A query editor URL:
     *    /_queries/edit/2644/?queryId=...
     */
    function getWorkItemId() {
        const workItemPathMatch = window.location.pathname.match(
            /\/_workitems\/edit\/(\d+)(?:\/|$)/i
        );

        if (workItemPathMatch) {
            return workItemPathMatch[1];
        }

        const queryEditorPathMatch = window.location.pathname.match(
            /\/_queries\/edit\/(\d+)(?:\/|$)/i
        );

        if (queryEditorPathMatch) {
            return queryEditorPathMatch[1];
        }

        const queryWorkItemId = new URLSearchParams(window.location.search).get(
            "workitem"
        );

        if (queryWorkItemId && /^\d+$/.test(queryWorkItemId)) {
            return queryWorkItemId;
        }

        return null;
    }

    /**
     * Gets information about the currently selected or open work item.
     */
    function getCurrentWorkItem() {
        const organizationAndProject = getOrganizationAndProject();

        const id = getWorkItemId();

        if (!organizationAndProject || !id) {
            return null;
        }

        const { organization, project } = organizationAndProject;

        const canonicalUrl =
            `${window.location.origin}/` +
            `${encodeURIComponent(organization)}/` +
            `${encodeURIComponent(project)}/` +
            `_workitems/edit/${encodeURIComponent(id)}`;

        return {
            organization,
            project,
            id,
            url: canonicalUrl,
        };
    }

    /**
     * Gets the work item title through the Azure DevOps REST API.
     * The browser's current Azure DevOps session is used.
     */
    async function getWorkItemTitle(workItem) {
        const organization = encodeURIComponent(workItem.organization);

        const project = encodeURIComponent(workItem.project);

        const id = encodeURIComponent(workItem.id);

        const apiUrl =
            `${window.location.origin}/${organization}/${project}` +
            `/_apis/wit/workitems/${id}` +
            `?fields=System.Title&api-version=7.1`;
        const controller = new AbortController();
        const timeout = window.setTimeout(
            () => controller.abort(),
            REQUEST_TIMEOUT_MS
        );

        let response;

        try {
            response = await fetch(apiUrl, {
                method: "GET",
                credentials: "same-origin",
                headers: {
                    Accept: "application/json",
                },
                signal: controller.signal,
            });
        } catch (error) {
            if (error.name === "AbortError") {
                throw new Error(
                    "Timed out while retrieving the work item title."
                );
            }

            throw error;
        } finally {
            window.clearTimeout(timeout);
        }

        if (!response.ok) {
            throw new Error(
                `Azure DevOps returned HTTP ${response.status}: ` +
                    response.statusText
            );
        }

        const data = await response.json();
        const title = data?.fields?.["System.Title"];

        if (typeof title !== "string" || title.trim() === "") {
            throw new Error("Azure DevOps did not return a work item title.");
        }

        // Remove leading and trailing whitespace from the title.
        return title.trim();
    }

    /**
     * Builds compact link HTML without leading or trailing whitespace.
     */
    function createLinkHtml(url, label) {
        const anchor = document.createElement("a");

        anchor.setAttribute("href", url);
        anchor.textContent = label.trim();

        // outerHTML contains only the anchor and no surrounding spaces.
        return anchor.outerHTML.trim();
    }

    /**
     * Copies the rich-text link using Violentmonkey's privileged
     * clipboard API.
     */
    function copyRichLink(url, label) {
        if (typeof GM_setClipboard !== "function") {
            throw new Error("GM_setClipboard is unavailable.");
        }

        // Explicitly remove any whitespace at the beginning or end.
        const cleanLabel = String(label).trim();
        const html = createLinkHtml(url, cleanLabel);

        GM_setClipboard(html, "text/html");
    }

    function resetButtonStatus() {
        isCopying = false;

        const button = getButton();

        if (!button) {
            return;
        }

        button.textContent = DEFAULT_BUTTON_TEXT;
        button.style.backgroundColor = "#5c2d91";
        button.disabled = false;
    }

    function getButton() {
        return document.getElementById(BUTTON_ID);
    }

    function showButtonStatus(message, status = "normal", resetAfter = true) {
        const button = getButton();

        if (!button) {
            return;
        }

        window.clearTimeout(statusTimer);

        button.textContent = message;

        switch (status) {
            case "success":
                button.style.backgroundColor = "#107c10";
                break;

            case "error":
                button.style.backgroundColor = "#a4262c";
                break;

            default:
                button.style.backgroundColor = "#5c2d91";
                break;
        }

        if (resetAfter) {
            statusTimer = window.setTimeout(resetButtonStatus, 2500);
        }
    }

    async function copyCurrentWorkItemLink() {
        if (isCopying) {
            return;
        }

        const workItem = getCurrentWorkItem();
        const button = getButton();

        if (!workItem) {
            showButtonStatus("No selected work item", "error");
            return;
        }

        isCopying = true;

        if (button) {
            button.disabled = true;
            button.style.filter = "";
        }

        showButtonStatus("Getting title...", "normal", false);

        try {
            const title = await getWorkItemTitle(workItem);

            // trim() ensures that no extra whitespace is included.
            const label = `#${workItem.id} - ${title}`.trim();

            copyRichLink(workItem.url, label);

            showButtonStatus("Copied!", "success");

            console.info("[Azure DevOps Copy Work Item Link]", {
                url: workItem.url,
                label,
            });
        } catch (error) {
            console.error("[Azure DevOps Copy Work Item Link]", error);

            showButtonStatus("Copy failed", "error");
        }
    }

    function createButton() {
        if (getButton()) {
            return;
        }

        const button = document.createElement("button");

        button.id = BUTTON_ID;
        button.type = "button";
        button.textContent = DEFAULT_BUTTON_TEXT;
        button.title = "Copy the selected work item as a link (Alt+Shift+C)";

        Object.assign(button.style, {
            position: "fixed",
            right: "20px",
            bottom: "20px",
            zIndex: "2147483647",
            display: "none",
            padding: "9px 14px",
            border: "1px solid rgba(255, 255, 255, 0.35)",
            borderRadius: "4px",
            backgroundColor: "#5c2d91",
            color: "#ffffff",
            fontFamily: '"Segoe UI", Arial, sans-serif',
            fontSize: "13px",
            fontWeight: "600",
            lineHeight: "18px",
            cursor: "pointer",
            boxShadow: "0 2px 8px rgba(0, 0, 0, 0.3)",
        });

        button.addEventListener("mouseenter", () => {
            if (!button.disabled) {
                button.style.filter = "brightness(1.15)";
            }
        });

        button.addEventListener("mouseleave", () => {
            button.style.filter = "";
        });

        button.addEventListener("click", copyCurrentWorkItemLink);

        document.body.appendChild(button);
    }

    function updateButtonVisibility() {
        const button = getButton();

        if (!button) {
            return;
        }

        const workItem = getCurrentWorkItem();

        if (!workItem && isCopying) {
            window.clearTimeout(statusTimer);
            resetButtonStatus();
        }

        button.style.display = workItem ? "block" : "none";

        if (workItem) {
            button.title =
                `Copy work item #${workItem.id} as a link ` + "(Alt+Shift+C)";
        } else {
            button.title =
                "Copy the selected work item as a link " + "(Alt+Shift+C)";
        }
    }

    function watchForAzureDevOpsNavigation() {
        window.addEventListener("popstate", updateButtonVisibility);
        window.addEventListener("hashchange", updateButtonVisibility);

        for (const methodName of ["pushState", "replaceState"]) {
            const originalMethod = window.history[methodName];

            window.history[methodName] = function (...args) {
                const result = originalMethod.apply(this, args);
                window.queueMicrotask(updateButtonVisibility);
                return result;
            };
        }
    }

    function registerKeyboardShortcut() {
        document.addEventListener("keydown", (event) => {
            if (
                event.altKey &&
                event.shiftKey &&
                !event.ctrlKey &&
                !event.metaKey &&
                event.code === "KeyC" &&
                !event.repeat &&
                !event.isComposing
            ) {
                event.preventDefault();
                copyCurrentWorkItemLink();
            }
        });
    }

    function registerMenuCommand() {
        if (typeof GM_registerMenuCommand !== "function") {
            return;
        }

        GM_registerMenuCommand(
            "Copy current Azure DevOps work item link",
            copyCurrentWorkItemLink
        );
    }

    function initialize() {
        createButton();
        updateButtonVisibility();
        watchForAzureDevOpsNavigation();
        registerKeyboardShortcut();
        registerMenuCommand();
    }

    initialize();
})();
