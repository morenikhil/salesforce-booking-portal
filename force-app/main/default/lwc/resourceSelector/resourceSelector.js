import { LightningElement, track } from 'lwc';
import searchAvailability from '@salesforce/apex/BookingEngineController.searchAvailability';
import createHold        from '@salesforce/apex/BookingEngineController.createHold';

const RESOURCE_TYPES = [
    { value: 'room',        label: 'Room',        icon: 'utility:home',      cssClass: 'type-tab' },
    { value: 'seat',        label: 'Seat',         icon: 'utility:groups',    cssClass: 'type-tab' },
    { value: 'appointment', label: 'Appointment',  icon: 'utility:event',     cssClass: 'type-tab' },
    { value: 'equipment',   label: 'Equipment',    icon: 'utility:settings',  cssClass: 'type-tab' },
];

export default class ResourceSelector extends LightningElement {
    @track selectedType    = 'room';
    @track selectedDate    = '';
    @track preferredTime   = '';
    @track partySize       = 1;
    @track availableResources = [];
    @track isSearching     = false;
    @track selectedResourceId = null;
    @track selectedSlotId  = null;
    @track isCreatingHold  = false;

    get today() {
        return new Date().toISOString().split('T')[0];
    }

    get resourceTypes() {
        return RESOURCE_TYPES.map(rt => ({
            ...rt,
            cssClass: ['type-tab', rt.value === this.selectedType ? 'active' : ''].join(' ').trim(),
        }));
    }

    get hasResults()  { return this.availableResources.length > 0 && !this.isSearching; }
    get noResults()   { return this.availableResources.length === 0 && !this.isSearching && this._searched; }

    _searched = false;

    // ── Filters ──────────────────────────────────────────────────────────────
    handleTypeChange(evt)      { this.selectedType  = evt.currentTarget.dataset.value; }
    handleDateChange(evt)      { this.selectedDate  = evt.detail.value; }
    handleTimeChange(evt)      { this.preferredTime = evt.detail.value; }
    handlePartySizeChange(evt) { this.partySize      = parseInt(evt.detail.value, 10) || 1; }

    // ── Search ───────────────────────────────────────────────────────────────
    async searchAvailability() {
        this.isSearching = true;
        this._searched   = true;
        this.selectedResourceId = null;
        this.selectedSlotId     = null;
        try {
            const results = await searchAvailability({
                resourceType:  this.selectedType,
                date:          this.selectedDate,
                preferredTime: this.preferredTime,
                partySize:     this.partySize,
            });
            this.availableResources = results.map(r => this.enrichResource(r));
        } catch (e) {
            console.error('Availability search failed', e);
            this.availableResources = [];
        } finally {
            this.isSearching = false;
        }
    }

    enrichResource(r) {
        const formatter = new Intl.NumberFormat('en-US', { style: 'currency', currency: r.currency || 'USD' });
        return {
            ...r,
            isSelected:    false,
            formattedPrice: formatter.format(r.basePrice),
            badgeCss:      r.status === 'Available' ? 'badge badge-green' : 'badge badge-red',
            cssClass:      'resource-card',
            timeSlots:     (r.timeSlots || []).map(s => ({
                ...s,
                cssClass: ['slot-btn', s.unavailable ? 'slot-unavailable' : ''].join(' ').trim(),
            })),
        };
    }

    // ── Resource click → show time slots ────────────────────────────────────
    handleResourceClick(evt) {
        const id = evt.currentTarget.dataset.id;
        this.selectedResourceId = id;
        this.selectedSlotId     = null;
        this.availableResources = this.availableResources.map(r => ({
            ...r,
            isSelected: r.id === id,
            cssClass: ['resource-card', r.id === id ? 'selected' : ''].join(' ').trim(),
        }));
    }

    // ── Slot select ──────────────────────────────────────────────────────────
    handleSlotSelect(evt) {
        this.selectedSlotId = evt.currentTarget.dataset.slotId;
        const rid = evt.currentTarget.dataset.resourceId;
        this.availableResources = this.availableResources.map(r => {
            if (r.id !== rid) return r;
            return {
                ...r,
                timeSlots: r.timeSlots.map(s => ({
                    ...s,
                    cssClass: ['slot-btn', s.id === this.selectedSlotId ? 'slot-selected' : '', s.unavailable ? 'slot-unavailable' : ''].join(' ').trim(),
                })),
            };
        });
    }

    // ── Confirm → create hold → emit events ─────────────────────────────────
    async confirmSelection() {
        const resource = this.availableResources.find(r => r.id === this.selectedResourceId);
        const slot     = resource?.timeSlots.find(s => s.id === this.selectedSlotId);
        if (!resource || !slot) return;

        this.isCreatingHold = true;
        try {
            const hold = await createHold({
                resourceId: resource.id,
                slotId:     slot.id,
                partySize:  this.partySize,
            });

            this.dispatchEvent(new CustomEvent('resourceselected', {
                detail: {
                    resourceId:   resource.id,
                    resourceName: resource.name,
                    slotId:       slot.id,
                    formattedSlot: slot.label,
                    date:         this.selectedDate,
                    partySize:    this.partySize,
                    basePrice:    resource.basePrice,
                    currency:     resource.currency || 'USD',
                    duration:     slot.duration,
                    priceUnit:    resource.priceUnit,
                },
            }));

            this.dispatchEvent(new CustomEvent('holdcreated', {
                detail: { holdId: hold.holdId },
            }));
        } catch (e) {
            console.error('Hold creation failed', e);
        } finally {
            this.isCreatingHold = false;
        }
    }

    handleImageError(evt) {
        evt.target.src = '/resource/BookingPlaceholder';
    }
}
