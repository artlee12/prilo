'use strict';

const { parse, request, wake, offlineCodes } = require('./transport');

module.exports = api => {
  class PriloPC {
    constructor(log, config) {
      this.log = log;
      this.connection = parse(config);
      this.wakingUntil = 0;
      this.switch = new api.hap.Service.Switch(config.name);
      this.switch.getCharacteristic(api.hap.Characteristic.On)
        .onGet(() => this.isOn())
        .onSet(value => this.setOn(value));
    }

    getServices() {
      return [this.switch];
    }

    async isOn() {
      try {
        const status = await request(this.connection, false);
        if (status !== 204) throw new Error(`Prilo power status rejected (HTTP ${status})`);
        this.wakingUntil = 0;
        return true;
      } catch (error) {
        if (offlineCodes.has(error.code)) return Date.now() < this.wakingUntil;
        this.log.warn(error.message);
        throw error;
      }
    }

    async setOn(on) {
      try {
        if (on) {
          await wake(this.connection);
          this.wakingUntil = Date.now() + 45000;
        } else {
          const status = await request(this.connection, true);
          if (status !== 202) throw new Error(`Prilo lock rejected (HTTP ${status})`);
          this.wakingUntil = 0;
        }
      } catch (error) {
        this.log.warn(error.message);
        throw error;
      }
    }
  }

  api.registerAccessory('PriloPC', PriloPC);
};
