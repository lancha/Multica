"use client";

import { useEffect, useRef, useState } from "react";
import { HoverCard, HoverCardTrigger, HoverCardContent } from "@multica/ui/components/ui/hover-card";
import { useActorName } from "@multica/core/workspace/hooks";
import { AgentProfileCard } from "../agents/components/agent-profile-card";
import { AgentLivePeekCard } from "../agents/components/agent-live-peek-card";
import { MemberProfileCard } from "../members/member-profile-card";
import { SquadProfileCard } from "../squads/components/squad-profile-card";
import { ActorAvatarIdentity, type ActorAvatarProps, type AgentHoverCardVariant } from "./actor-avatar-identity";

export { AgentStatusDot } from "./actor-avatar-identity";
export type { AgentHoverCardVariant } from "./actor-avatar-identity";

const FOCUSABLE_ANCESTOR_SELECTOR =
  'a[href], button:not([disabled]), [role="button"]:not([aria-disabled="true"]), [tabindex]:not([tabindex="-1"])';

export function ActorAvatar(props: ActorAvatarProps) {
  const { hasActor } = useActorName();
  const content = <ActorAvatarIdentity {...props} />;
  const profileAvailable = !props.profileRequiresDirectoryEntry || hasActor(props.actorType, props.actorId) !== false;
  if (!props.enableHoverCard || !profileAvailable) return content;
  if (props.actorType === "agent") {
    return <AgentAvatarHoverCard agentId={props.actorId} variant={props.hoverCardVariant ?? "profile"}>{content}</AgentAvatarHoverCard>;
  }
  if (props.actorType === "member") return <MemberAvatarHoverCard userId={props.actorId}>{content}</MemberAvatarHoverCard>;
  if (props.actorType === "squad") return <SquadAvatarHoverCard squadId={props.actorId}>{content}</SquadAvatarHoverCard>;
  return content;
}

/**
 * Wraps an agent avatar in a hover-card. The trigger is keyboard-focusable
 * only when no focusable ancestor (link/button) already provides a tab stop —
 * this prevents nested tabbable descendants and keyboard-nav bloat at sites
 * where the avatar lives inside a row link or click target.
 */
function AgentAvatarHoverCard({
  agentId,
  variant,
  children,
}: {
  agentId: string;
  variant: AgentHoverCardVariant;
  children: React.ReactNode;
}) {
  const content =
    variant === "live" ? (
      <AgentLivePeekCard agentId={agentId} />
    ) : (
      <AgentProfileCard agentId={agentId} />
    );
  return (
    <ActorAvatarHoverCardShell content={content}>
      {children}
    </ActorAvatarHoverCardShell>
  );
}

function MemberAvatarHoverCard({
  userId,
  children,
}: {
  userId: string;
  children: React.ReactNode;
}) {
  return (
    <ActorAvatarHoverCardShell content={<MemberProfileCard userId={userId} />}>
      {children}
    </ActorAvatarHoverCardShell>
  );
}

function SquadAvatarHoverCard({
  squadId,
  children,
}: {
  squadId: string;
  children: React.ReactNode;
}) {
  return (
    <ActorAvatarHoverCardShell content={<SquadProfileCard squadId={squadId} />}>
      {children}
    </ActorAvatarHoverCardShell>
  );
}

// Common chrome shared between agent and member hover cards. Keeps focus
// behaviour and width consistent so the two surfaces feel structurally
// parallel — content varies, frame doesn't.
//
// Do NOT defer-mount the HoverCard on pointerenter to save per-avatar mount
// cost (MUL-4827). Base UI drives hover through native mouseenter/mouseleave
// listeners on the trigger element, and installs its close path *inside* the
// mouseleave handler — so a trigger that never received a real mouseenter can
// neither cancel a pending open nor ever hover-close. Warming on pointerenter
// swaps the node mid-gesture and loses exactly those events, which made
// brushed-past avatars pop open ~600ms later and stick. This is the same
// invariant DeferredPopup documents: deferral is only sound for events that
// END a gesture (click/Enter), and hover starts one. Mounting the root eagerly
// costs ~0.15ms of JS per avatar and adds zero DOM while closed (the popup
// subtree, and its queries, stay unmounted until open).
function ActorAvatarHoverCardShell({
  content,
  children,
}: {
  content: React.ReactNode;
  children: React.ReactNode;
}) {
  const triggerRef = useRef<HTMLSpanElement>(null);
  const [standalone, setStandalone] = useState(false);

  useEffect(() => {
    const el = triggerRef.current;
    if (!el) return;
    const ancestor = el.parentElement?.closest(FOCUSABLE_ANCESTOR_SELECTOR);
    setStandalone(!ancestor);
  }, []);

  const tabIndex = standalone ? 0 : -1;
  const className = standalone
    ? "inline-flex cursor-pointer rounded-full focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
    : "inline-flex cursor-pointer";

  return (
    <HoverCard>
      <HoverCardTrigger
        render={<span ref={triggerRef} />}
        tabIndex={tabIndex}
        className={className}
      >
        {children}
      </HoverCardTrigger>
      <HoverCardContent align="start" className="w-72">
        {content}
      </HoverCardContent>
    </HoverCard>
  );
}
