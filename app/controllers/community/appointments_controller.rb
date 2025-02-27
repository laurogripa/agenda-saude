module Community
  class AppointmentsController < Base
    class CannotCancelAndReschedule < StandardError; end

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def home
      if current_patient.force_user_update?
        return redirect_to(edit_community_patient_path, flash: { alert: I18n.t('alerts.update_patient_profile') })
      end

      return redirect_to(vaccinated_community_appointments_path) if current_patient.vaccinated?

      @doses = current_patient.doses.includes(:vaccine, appointment: [:ubs])
      @appointment = current_patient.appointments.current

      if @appointment.present?
        @can_cancel_or_reschedule = can_cancel_and_reschedule?
        @can_change_after = current_patient.change_reschedule_after
        return
      end

      return unless current_patient.can_schedule?

      if current_patient.doses.exists?
        @appointments_count = Appointment.waiting.not_scheduled
                                        .where(start: from..to, ubs_id: allowed_ubs_ids)
                                        .count
      else
        @appointments_count = Appointment.available_doses
                                         .where(start: from..to, ubs_id: allowed_ubs_ids)
                                         .count
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # Schedules appointment
    # rubocop:disable Metrics/AbcSize
    def index
      appointment_can_cancel_and_reschedule

      # If patient already had a dose, show only UBS that are 'enabled_for_reschedule'.
      if current_patient.doses.exists?
        rescheduled = true
      else
        rescheduled = false
      end

      @days = parse_days(rescheduled)
      @appointments = scheduler.open_times_per_ubs(from: @days.days.from_now.beginning_of_day,
                                                   to: @days.days.from_now.end_of_day,
                                                   filter_ubs_id: allowed_ubs_ids,
                                                   reschedule: rescheduled)
                               .sort_by { |ubs, _appointments| ubs.name }
    rescue AppointmentScheduler::NoFreeSlotsAhead
      redirect_to home_community_appointments_path, flash: { alert: 'Não há vagas disponíveis para reagendamento.' }
    rescue CannotCancelAndReschedule
      redirect_to home_community_appointments_path, flash: { alert: 'Você não pode cancelar ou reagendar.' }
    end
    # rubocop:enable Metrics/AbcSize

    # rubocop:disable Metrics/AbcSize
    def create
      appointment_can_cancel_and_reschedule

      # If patient already had a dose, keep it in the same UBS
      if current_patient.doses.exists?
        ubs_id = create_params[:ubs_id].to_i
        rescheduled = true

      # Intersection between allowed and requested, will return nil (which is fine) if forbidden
      else
        ubs_id = (allowed_ubs_ids & [create_params[:ubs_id].to_i]).first if ubs_id.blank? && create_params[:ubs_id]
        rescheduled = false
      end

      result, new_appointment = scheduler.schedule(
        patient: current_patient,
        ubs_id: ubs_id,
        from: parse_start.presence,
        reschedule: rescheduled
      )

      redirect_to home_community_appointments_path,
                  flash: message_for(result, appointment: new_appointment, desired_start: parse_start)
    rescue CannotCancelAndReschedule
      redirect_to home_community_appointments_path, flash: { alert: 'Você não pode cancelar ou reagendar.' }
    end
    # rubocop:enable Metrics/AbcSize

    # NOTE: we are ignoring params[:id] in here
    def destroy
      @appointment = appointment_can_cancel_and_reschedule

      scheduler.cancel_schedule(appointment: @appointment)

      redirect_to home_community_appointments_path
    end

    def vaccinated
      return redirect_to(home_community_appointments_path) unless current_patient.vaccinated?

      @patient = current_patient
      @doses = current_patient.doses.order(:sequence_number)
    end

    private

    def appointment_can_cancel_and_reschedule
      raise CannotCancelAndReschedule unless can_cancel_and_reschedule?

      current_patient.appointments.not_checked_out.current
    end

    def can_cancel_and_reschedule?
      current_appointment = current_patient.appointments.not_checked_out.current

      if current_patient.doses.exists?
        return false unless current_patient.got_reschedule_condition?
      elsif current_appointment.present?
        return false if current_appointment.follow_up_for_dose && Time.zone.now < current_appointment.start
      end

      true
    end

    def from
      Rails.configuration.x.schedule_from_hours.hours.from_now
    end

    def to
      Rails.configuration.x.schedule_up_to_days.days.from_now.end_of_day
    end

    def scheduler
      AppointmentScheduler.new(earliest_allowed: from, latest_allowed: to)
    end

    def message_for(result, appointment:, desired_start:)
      case result
      when AppointmentScheduler::CONDITIONS_UNMET
        {
          alert: 'Você não está entre grupos que podem fazer agendamentos.',
          cy: 'appointmentSchedulerConditionsUnmetAlertText'
        }
      when AppointmentScheduler::NO_SLOTS
        {
          alert: 'Desculpe, mas não foi possível agendar devido a disponibilidade da vaga. Tente novamente.'
        }
      when AppointmentScheduler::SUCCESS
        {
          notice: success_message(desired_start, appointment.start)
        }
      else
        raise "Unexpected result #{result}"
      end
    end

    def success_message(desired_date, scheduled_date)
      if desired_date.present? && (desired_date - scheduled_date).abs > AppointmentScheduler::ROUNDING
        'Vacinação agendada. No entanto, a data e/ou hora que você selecionou foi ocupada por outra pessoa. ' \
          'Confira abaixo a nova data e horário que o sistema encontrou para você!'
      else
        'Vacinação agendada.'
      end
    end

    # Loads pages for the Index, between 0 and max possible allowed
    def parse_days(reschedule)
      [
        [
          0,
          params[:page].presence&.to_i || scheduler.days_ahead_with_open_slot(reschedule: reschedule)
        ].compact.max,
        Rails.configuration.x.schedule_up_to_days
      ].min
    end

    def parse_start
      create_params[:start].present? && Time.zone.parse(create_params[:start])
    rescue ArgumentError
      nil
    end

    def allowed_ubs_ids
      if current_patient.doses.exists?
        Ubs.where(enabled_for_reschedule: true).pluck(:id)
      else
        current_patient.conditions.flat_map(&:ubs_ids).uniq
      end
    end

    def create_params
      params.require(:appointment).permit(:ubs_id, :start)
    end

    def slot_params
      params.permit(:gap_in_days)
    end
  end
end
