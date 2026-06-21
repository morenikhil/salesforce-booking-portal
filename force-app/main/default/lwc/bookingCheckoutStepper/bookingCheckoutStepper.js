import { LightningElement, track } from 'lwc';
import releaseHold from '@salesforce/apex/BookingEngineController.releaseHold';

const STEPS = [
    { id: 1, number: 1, label: 'Select',  done: false },
    { id: 2, number: 2, label: 'Pricing', done: false },
    { id: 3, number: 3, label: 'Payment', done: false },
    { id: 4, number: 4, label: 'Confirm', done: false },
];

const HOLD_DURATION_SECONDS = 600; // 10 minutes

export default class BookingCheckoutStepper extends LightningElement {
    @track currentStep = 1;
    @track bookingDraft = {};
    @track bookingReference = null;
    @track holdActive = false;
    @track holdCountdown = '';
    @track errorMessage = null;

    holdId = null;
    holdTimer = null;
    holdSecondsLeft = HOLD_DURATION_SECONDS;

    // ── Step visibility ──────────────────────────────────────────────────────
    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get isStep4() { return this.currentStep === 4; }

    // ── Progress bar items ───────────────────────────────────────────────────
    get steps() {
        return STEPS.map((s, i) => {
            const active  = s.id === this.currentStep;
            const done    = s.id < this.currentStep;
            return {
                ...s,
                done,
                cssClass: ['step-item', active ? 'active' : '', done ? 'done' : ''].join(' ').trim(),
            };
        });
    }

    // ── Step 1 → Step 2 ──────────────────────────────────────────────────────
    handleResourceSelected(evt) {
        this.bookingDraft = { ...this.bookingDraft, ...evt.detail };
    }

    handleHoldCreated(evt) {
        this.holdId = evt.detail.holdId;
        this.holdSecondsLeft = HOLD_DURATION_SECONDS;
        this.holdActive = true;
        this.startHoldTimer();
        this.currentStep = 2;
    }

    // ── Step 2 → Step 3 ──────────────────────────────────────────────────────
    handlePricingConfirmed(evt) {
        this.bookingDraft = { ...this.bookingDraft, pricing: evt.detail };
        this.currentStep = 3;
    }

    // ── Step 3 → Step 4 ──────────────────────────────────────────────────────
    handlePaymentComplete(evt) {
        this.bookingReference = evt.detail.bookingReference;
        this.stopHoldTimer();
        this.holdActive = false;
        this.currentStep = 4;
    }

    // ── Back navigation ──────────────────────────────────────────────────────
    goBack() {
        if (this.currentStep > 1) this.currentStep -= 1;
    }

    // ── Hold countdown timer ─────────────────────────────────────────────────
    startHoldTimer() {
        this.holdTimer = setInterval(() => {
            this.holdSecondsLeft -= 1;
            const m = Math.floor(this.holdSecondsLeft / 60).toString().padStart(2, '0');
            const s = (this.holdSecondsLeft % 60).toString().padStart(2, '0');
            this.holdCountdown = `${m}:${s}`;

            if (this.holdSecondsLeft <= 0) {
                this.stopHoldTimer();
                this.holdActive = false;
                this.currentStep = 1;
                this.errorMessage = 'Your hold expired. Please select again.';
                this.releaseHoldOnServer();
            }
        }, 1000);
    }

    stopHoldTimer() {
        if (this.holdTimer) {
            clearInterval(this.holdTimer);
            this.holdTimer = null;
        }
    }

    async releaseHoldOnServer() {
        if (!this.holdId) return;
        try {
            await releaseHold({ holdId: this.holdId });
        } catch (e) {
            // best-effort — server TTL will clean up automatically
        }
        this.holdId = null;
    }

    // ── Error handling ───────────────────────────────────────────────────────
    clearError() { this.errorMessage = null; }

    disconnectedCallback() {
        this.stopHoldTimer();
    }
}
