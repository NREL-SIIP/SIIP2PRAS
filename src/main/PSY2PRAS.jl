#######################################################
# Surya
# NREL
# January 2021
# SIIP --> PRAS Linkage Module
#######################################################
# Loading the required packages
#######################################################
const PSY = PowerSystems
#######################################################
# Outage Information CSV
#######################################################
const OUTAGE_INFO_FILE =
    joinpath(@__DIR__, "descriptors", "outage-rates-ERCOT-modified.csv") 

df_outage = DataFrames.DataFrame(CSV.File(OUTAGE_INFO_FILE));
#######################################################
# Structs to parse and store the outage information
#######################################################
struct outage_data
    prime_mover::String
    thermal_fuel::String
    capacity::Int64
    FOR::Float64
    MTTR::Int64

    outage_data(prime_mover  = "PrimeMovers.Default", thermal_fuel ="ThermalFuels.Default", capacity = 100, FOR=0.5,MTTR = 50) =new(prime_mover,thermal_fuel,capacity,FOR,MTTR)
end 

outage_values =[]
for row in eachrow(df_outage)
    push!(outage_values, outage_data(row.PrimeMovers,row.ThermalFuels,row.NameplateLimit_MW,(row.FOR/100),row.MTTR))
end
#######################################################
# Aux Functions
# Function to get Line Rating
#######################################################
function line_rating(line::Union{PSY.Line,PSY.MonitoredLine})
    rate = PSY.get_rate(line);
    return(forward_capacity = rate , backward_capacity = rate)
end

function line_rating(line::PSY.HVDCLine)
    forward_capacity = getfield(PSY.get_active_power_limits_from(line), :max)
    backward_capacity = getfield(PSY.get_active_power_limits_to(line), :max)
    return(forward_capacity = forward_capacity, backward_capacity = backward_capacity)
end
#######################################################
# Function to get available components in AggregationTopology
#######################################################
function get_available_components_in_aggregation_topology(type::Type{<:PowerSystems.StaticInjection}, sys::PSY.System, region::PSY.AggregationTopology)
    avail_comps =  [comp for comp in PSY.get_components_in_aggregation_topology(type, sys, region) if (PSY.get_available(comp))]

    return avail_comps
end
#######################################################
# Functions to get generator category
#######################################################
function get_generator_category(gen::GEN) where {GEN <: PSY.RenewableGen}
    return string(PSY.get_prime_mover(gen))
end

function get_generator_category(gen::GEN) where {GEN <: PSY.ThermalGen}
    return string(PSY.get_fuel(gen))
end

function get_generator_category(gen::GEN) where {GEN <: PSY.HydroGen}
    return "Hydro"
end

function get_generator_category(stor::GEN) where {GEN <: PSY.Storage}
    if (occursin("Distributed",PSY.get_name(stor)))
        return "Distributed_Storage"
    elseif (occursin("Battery",PSY.get_name(stor)))
        return "Battery_Storage"
    else
        return "Battery"
    end
end

function get_generator_category(stor::GEN) where {GEN <: PSY.HybridSystem}
    return "Hybrid-System"
end
##############################################
# Converting FOR and MTTR to ?? and ??
##############################################
function outage_to_rate(outage_data::Tuple{Float64, Int64})
    for_gen = outage_data[1]
    mttr = outage_data[2]

    if (for_gen >1.0)
        for_gen = for_gen/100
    end

    if (mttr != 0)
        ?? = 1 / mttr
    else
        ?? = 0.0
    end
    ?? = (?? * for_gen) / (1 - for_gen)
    #?? = for_gen

    return (?? = ??, ?? = ??)
end
#######################################################
# Main Function to make the PRAS System
#######################################################
function make_pras_system(sys::PSY.System;
                          system_model::Union{Nothing, String} = nothing,aggregation::Union{Nothing, String} = nothing,
                          period_of_interest::Union{Nothing, UnitRange} = nothing,outage_flag=true,lump_pv_wind_gens=false,availability_flag=false, 
                          outage_csv_location::Union{Nothing, String} = nothing) 
    """
    make_pras_system(psy_sys,system_model)

    PSY System and System Model ("Single-Node","Zonal") are taken as arguments 
    and a PRAS SystemModel is returned.
    
    ...
    # Arguments
    - `psy_sys::PSY.System`: PSY System
    - `system_model::String`: "Single-Node" (or) "Zonal"
    - `aggregation::String`: "Area" (or) "LoadZone" {Optional} 
    - `num_time_steps::UnitRange`: Number of timesteps of PRAS SystemModel {Optional} 
    ...

    # Examples
    ```julia-repl
    julia> make_pras_system(psy_sys,system_model,period_of_interest)
    PRAS SystemModel
    ```
    """
    PSY.set_units_base_system!(sys, PSY.IS.UnitSystem.NATURAL_UNITS); # PRAS needs PSY System to be in NATURAL_UNITS
    #######################################################
    # Double counting of HybridSystem subcomponents
    #######################################################
    dup_uuids =[];
    h_s_comps = availability_flag ? PSY.get_components(PSY.HybridSystem, sys, PSY.get_available) : PSY.get_components(PSY.HybridSystem, sys)
    for h_s in h_s_comps
        h_s_subcomps = PSY._get_components(h_s)
        for subcomp in h_s_subcomps
            push!(dup_uuids,PSY.IS.get_uuid(subcomp))
        end
    end
    #######################################################
    # kwargs Handling
    #######################################################
    if (aggregation === nothing)
        aggregation_topology = "Area";
    end

    if (aggregation=="Area")
        aggregation_topology = PSY.Area;
    
    elseif (aggregation=="LoadZone")
        aggregation_topology = PSY.LoadZone;
    else
        error("Unrecognized PSY AggregationTopology")
    end

    all_ts = PSY.get_time_series_multiple(sys)
    first_ts_temp = first(all_ts);
    sys_ts_types = unique(typeof.(PSY.get_time_series_multiple(sys)));
    # Time series information
    sys_for_int_in_hour = round(Dates.Millisecond(PSY.get_forecast_interval(sys)), Dates.Hour)
    sys_res_in_hour = round(Dates.Millisecond(PSY.get_time_series_resolution(sys)), Dates.Hour)
    interval_len = Int(sys_for_int_in_hour.value/sys_res_in_hour.value)
    sys_horizon =  PSY.get_forecast_horizon(sys)
    #######################################################
    # Function to handle PSY timestamps
    #######################################################
    function get_period_of_interest(ts::TS) where {TS <: PSY.StaticTimeSeries}
        return range(1,length = length(ts.data))
    end

    function get_period_of_interest(ts::TS) where {TS <: PSY.Deterministic}
        return range(1,length = length(ts.data)*interval_len)
    end

    function get_len_ts_data(ts::TS) where {TS <: PSY.StaticTimeSeries}
        return length(ts.data)
    end

    function get_len_ts_data(ts::TS) where {TS <: PSY.Deterministic}
        return length(ts.data)*interval_len
    end
    
    if (period_of_interest === nothing)
        period_of_interest = get_period_of_interest(first_ts_temp)
    else
        if (PSY.Deterministic in sys_ts_types)
            if !(period_of_interest.start %  interval_len ==1 && period_of_interest.stop %  interval_len == 0)
                error("This PSY System has Determinstic time series data with interval length of $(interval_len). The period of interest should therefore be multiples of $(interval_len) to account for forecast windows.")
            end
        end
    end

    N = length(period_of_interest);
    len_ts_data = get_len_ts_data(first_ts_temp)

    if ((N+(period_of_interest.start-1))> len_ts_data)
        error("Cannot make a PRAS System with $(N) timesteps with a PSY System with only $(length(first_ts_temp.data) - (period_of_interest.start-1)) timesteps of time series data")
    end
    if (period_of_interest.start >  len_ts_data || period_of_interest.stop >  len_ts_data)
        error("Please check the system period of interest selected")
    end

    # Check if all time series data has a scaling_factor_multiplier
    if(!all(.!isnothing.(getfield.(all_ts,:scaling_factor_multiplier))))
        error("Not all time series associated with components have scaling factor multipliers. This might lead to discrepancies in time series data in the PRAS System.")
    end
    # if outage_csv_location is passed, perform some data checks
    outage_ts_flag = false
    if (outage_csv_location !== nothing)
        outage_ts_data,outage_ts_flag = try
            @info "Parsing the CSV with outage time series data ..."
            DataFrames.DataFrame(CSV.File(outage_csv_location)), true
        catch ex
            error("Couldn't parse the CSV with outage data at $(outage_csv_location).") 
            throw(ex)
        end
    end
    if (outage_ts_flag)
        if (N>DataFrames.nrow(outage_ts_data))
            @warn "Outage time series data is not available for all System timestamps in the CSV."
        end
    end
    #######################################################
    # PRAS timestamps
    # Need this to select timeseries values of interest
    #######################################################
    start_datetime = PSY.IS.get_initial_timestamp(first_ts_temp);
    start_datetime = start_datetime + Dates.Hour((period_of_interest.start-1)*sys_res_in_hour);
    start_datetime_tz = TimeZones.ZonedDateTime(start_datetime,TimeZones.tz"UTC");
    finish_datetime_tz = start_datetime_tz +  Dates.Hour((N-1)*sys_res_in_hour);
    my_timestamps = StepRange(start_datetime_tz, Dates.Hour(sys_res_in_hour), finish_datetime_tz);
    @info "The first timestamp of PRAS System being built is : $(start_datetime_tz) and last timestamp is : $(finish_datetime_tz) "
    det_ts_period_of_interest = 
    if (PSY.Deterministic in sys_ts_types)
        strt = 
        if (round(Int,period_of_interest.start/interval_len) ==0)
            1
        else
            round(Int,period_of_interest.start/interval_len)
        end
        stp = round(Int,period_of_interest.stop/interval_len)

        range(strt,length = (stp-strt)+1)
        
    end
    #######################################################
    # Common function to handle getting time series values
    #######################################################
    function get_forecast_values(ts::TS) where {TS <: PSY.Deterministic}
        forecast_vals = []
        for it in collect(keys(PSY.get_data(ts)))[det_ts_period_of_interest]
            append!(forecast_vals,collect(values(PSY.get_window(ts, it; len=interval_len))))
        end
        return forecast_vals
    end
   
    function get_forecast_values(ts::TS) where {TS <: PSY.StaticTimeSeries}
        forecast_vals = values(PSY.get_data(ts))[period_of_interest]
        return forecast_vals
    end
    #######################################################
     # PRAS Regions - Areas in SIIP
    #######################################################
    @info "Processing Regions in PSY System... "
    regions = collect(PSY.get_components(aggregation_topology, sys));
    if (length(regions)!=0)
        @info "The PSY System has $(length(regions)) regions based on PSY AggregationTopology : $(aggregation_topology)."
    else
        error("No regions in the PSY System. Cannot proceed with the process of making a PRAS SystemModel.")
    end 

    region_names = PSY.get_name.(regions);
    num_regions = length(region_names);

    region_load = Array{Int64,2}(undef,num_regions,N);
   
    for (idx,region) in enumerate(regions)
        reg_load_comps = availability_flag ? get_available_components_in_aggregation_topology(PSY.PowerLoad, sys, region) :
                                             PSY.get_components_in_aggregation_topology(PSY.PowerLoad, sys, region)
      
        region_load[idx,:]=floor.(Int,sum(get_forecast_values.(first.(PSY.get_time_series_multiple.(reg_load_comps, name = "max_active_power")))
                        .*PSY.get_max_active_power.(reg_load_comps))); # Any issues with using the first of time_series_multiple?
    end

    new_regions = PRAS.Regions{N,PRAS.MW}(region_names, region_load);

    #######################################################
    # kwargs Handling
    #######################################################
    if (system_model === nothing)
        if (num_regions>1)
            system_model = "Zonal"
        else
            system_model = "Single-Node"
        end
    end
    #######################################################
    # Generator Region Indices
    #######################################################
    gens=Array{PSY.Generator}[];
    start_id = Array{Int64}(undef,num_regions); 
    region_gen_idxs = Array{UnitRange{Int64},1}(undef,num_regions); 
    reg_wind_gens_DA = []
    reg_pv_gens_DA = []

    if (lump_pv_wind_gens)
        for (idx,region) in enumerate(regions)
            reg_ren_comps = availability_flag ? get_available_components_in_aggregation_topology(PSY.RenewableGen, sys, region) :
                                                 PSY.get_components_in_aggregation_topology(PSY.RenewableGen, sys, region)
            wind_gs_DA= [g for g in reg_ren_comps if (PSY.get_prime_mover(g) == PSY.PrimeMovers.WT)] 
            pv_gs_DA= [g for g in reg_ren_comps if (PSY.get_prime_mover(g) == PSY.PrimeMovers.PVe)] 
            reg_gen_comps = availability_flag ? get_available_components_in_aggregation_topology(PSY.Generator, sys, region) :
                                                PSY.get_components_in_aggregation_topology(PSY.Generator, sys, region)
            gs= [g for g in reg_gen_comps if (typeof(g) != PSY.HydroEnergyReservoir && PSY.get_max_active_power(g)!=0 && 
                                              PSY.IS.get_uuid(g) ??? union(dup_uuids,PSY.IS.get_uuid.(wind_gs_DA),PSY.IS.get_uuid.(pv_gs_DA)))] 
            push!(gens,gs)
            push!(reg_wind_gens_DA,wind_gs_DA)
            push!(reg_pv_gens_DA,pv_gs_DA)

            if (idx==1)
                start_id[idx] = 1
            else 
                if (length(reg_wind_gens_DA[idx-1]) > 0 && length(reg_pv_gens_DA[idx-1]) > 0)
                    start_id[idx] =start_id[idx-1]+length(gens[idx-1])+2
                elseif (length(reg_wind_gens_DA[idx-1]) > 0 || length(reg_pv_gens_DA[idx-1]) > 0)
                    start_id[idx] =start_id[idx-1]+length(gens[idx-1])+1
                else
                    start_id[idx] =start_id[idx-1]+length(gens[idx-1])
                end
            end

            if (length(reg_wind_gens_DA[idx]) > 0 && length(reg_pv_gens_DA[idx]) > 0)
                region_gen_idxs[idx] = range(start_id[idx], length=length(gens[idx])+2)
            elseif (length(reg_wind_gens_DA[idx]) > 0 || length(reg_pv_gens_DA[idx]) > 0)
                region_gen_idxs[idx] = range(start_id[idx], length=length(gens[idx])+1)
            else
                region_gen_idxs[idx] = range(start_id[idx], length=length(gens[idx]))
            end
        end
    else
        for (idx,region) in enumerate(regions)
            reg_gen_comps = availability_flag ? get_available_components_in_aggregation_topology(PSY.Generator, sys, region) :
                                                PSY.get_components_in_aggregation_topology(PSY.Generator, sys, region)
            gs= [g for g in reg_gen_comps if (typeof(g) != PSY.HydroEnergyReservoir && PSY.get_max_active_power(g)!=0 && PSY.IS.get_uuid(g) ??? dup_uuids)]
            push!(gens,gs)
            idx==1 ? start_id[idx] = 1 : start_id[idx] =start_id[idx-1]+length(gens[idx-1])
            region_gen_idxs[idx] = range(start_id[idx], length=length(gens[idx]))
        end
    end
    #######################################################
    # Storages Region Indices
    #######################################################
    stors=[];
    start_id = Array{Int64}(undef,num_regions);
    region_stor_idxs = Array{UnitRange{Int64},1}(undef,num_regions);

    for (idx,region) in enumerate(regions)
        #push!(stors,[s for s in PSY.get_components_in_aggregation_topology(PSY.Storage, sys, region)])
        reg_stor_comps = availability_flag ? get_available_components_in_aggregation_topology(PSY.Storage, sys, region) :
                                             PSY.get_components_in_aggregation_topology(PSY.Storage, sys, region)
        push!(stors,[s for s in reg_stor_comps if (PSY.IS.get_uuid(s) ??? dup_uuids)])
        idx==1 ? start_id[idx] = 1 : start_id[idx] =start_id[idx-1]+length(stors[idx-1])
        region_stor_idxs[idx] = range(start_id[idx], length=length(stors[idx]))
    end
    #######################################################
    # GeneratorStorages Region Indices
    #######################################################
    gen_stors=[];
    start_id = Array{Int64}(undef,num_regions);
    region_genstor_idxs = Array{UnitRange{Int64},1}(undef,num_regions);

    for (idx,region) in enumerate(regions)
        reg_gen_stor_comps = availability_flag ? get_available_components_in_aggregation_topology(PSY.StaticInjection, sys, region) :
                                                 PSY.get_components_in_aggregation_topology(PSY.StaticInjection, sys, region)
        gs= [g for g in reg_gen_stor_comps if (typeof(g) == PSY.HydroEnergyReservoir || typeof(g)==PSY.HybridSystem)]
        push!(gen_stors,gs)
        idx==1 ? start_id[idx] = 1 : start_id[idx] =start_id[idx-1]+length(gen_stors[idx-1])
        region_genstor_idxs[idx] = range(start_id[idx], length=length(gen_stors[idx]))
    end
    #######################################################
    # PRAS Generators
    #######################################################
    @info "Processing Generators in PSY System... "
    
    # Lumping Wind and PV Generators per Region
    if (lump_pv_wind_gens)
        for i in 1: num_regions
            if (length(reg_wind_gens_DA[i])>0)
                # Wind
                temp_lumped_wind_gen = PSY.RenewableDispatch(nothing)
                PSY.set_name!(temp_lumped_wind_gen,"Lumped_Wind_"*region_names[i])
                PSY.set_prime_mover!(temp_lumped_wind_gen,PSY.PrimeMovers.WT)
                ext = PSY.get_ext(temp_lumped_wind_gen)
                ext["region_gens"] = reg_wind_gens_DA[i]
                ext["outage_probability"] = 0.0
                ext["recovery_probability"] = 1.0
                push!(gens[i],temp_lumped_wind_gen)
            end
            if (length(reg_pv_gens_DA[i])>0)
                # PV
                temp_lumped_pv_gen = PSY.RenewableDispatch(nothing)
                PSY.set_name!(temp_lumped_pv_gen,"Lumped_PV_"*region_names[i])
                PSY.set_prime_mover!(temp_lumped_pv_gen,PSY.PrimeMovers.PVe)
                ext = PSY.get_ext(temp_lumped_pv_gen)
                ext["region_gens"] = reg_pv_gens_DA[i]
                ext["outage_probability"] = 0.0
                ext["recovery_probability"] = 1.0
                push!(gens[i],temp_lumped_pv_gen)
            end
        end
    end

    gen=[];
    for i in 1: num_regions
        if (length(gens[i]) != 0)
            append!(gen,gens[i])
        end
    end
    
    if(length(gen) ==0)
        gen_names = String[];
    else
        gen_names = PSY.get_name.(gen);
    end

    gen_categories = string.(typeof.(gen));
    n_gen = length(gen_names);

    gen_cap_array = Matrix{Int64}(undef, n_gen, N);
    ??_gen = Matrix{Float64}(undef, n_gen, N);
    ??_gen = Matrix{Float64}(undef, n_gen, N);

    for (idx,g) in enumerate(gen)
        # Nominal outage and recovery rate
        (??,??) = (0.0,1.0)
        
        if (lump_pv_wind_gens && (PSY.get_prime_mover(g) == PSY.PrimeMovers.WT || PSY.get_prime_mover(g) == PSY.PrimeMovers.PVe))
            reg_gens_DA = PSY.get_ext(g)["region_gens"];
            gen_cap_array[idx,:] = round.(Int,sum(get_forecast_values.(first.(PSY.get_time_series_multiple.(reg_gens_DA, name = "max_active_power")))
                                   .*PSY.get_max_active_power.(reg_gens_DA)));
        else
            if (PSY.has_time_series(g) && ("max_active_power" in PSY.get_name.(PSY.get_time_series_multiple(g))))
                gen_cap_array[idx,:] = floor.(Int,get_forecast_values(first(PSY.get_time_series_multiple(g, name = "max_active_power")))
                                       *PSY.get_max_active_power(g));
            else
                gen_cap_array[idx,:] = fill.(floor.(Int,PSY.get_max_active_power(g)),1,N);
            end
        end

        if (outage_ts_flag)
            try
                @info "Using FOR time series data for $(PSY.get_name(g)) of type $(gen_categories[idx]). Assuming the mean time to recover (MTTR) is 24 hours to compute the ?? and ?? time series data ..."
                g_??_??_ts_data = outage_to_rate.(zip(outage_ts_data[!,PSY.get_name(g)],fill(24,length(outage_ts_data[!,PSY.get_name(g)]))))
                ??_gen[idx,:] = getfield.(g_??_??_ts_data,:??)
                ??_gen[idx,:] = getfield.(g_??_??_ts_data,:??) # This assumes a mean time to recover of 24 hours.
            catch ex
                @warn "FOR time series data for $(PSY.get_name(g)) of type $(gen_categories[idx]) is not available in the CSV. Using nominal outage and recovery probabilities for this generator." 
                ??_gen[idx,:] = fill.(??,1,N); 
                ??_gen[idx,:] = fill.(??,1,N);
            end
        else
            if (~outage_flag)
                if (gen_categories[idx] == "PowerSystems.ThermalStandard")
                    p_m = string(PSY.get_prime_mover(g))
                    fl = string(PSY.get_fuel(g))

                    p_m_idx = findall(x -> x == p_m, getfield.(outage_values,:prime_mover))
                    fl_idx =  findall(x -> x == fl, getfield.(outage_values[p_m_idx],:thermal_fuel))
                    
                    if (length(fl_idx) ==0)
                        fl_idx =  findall(x -> x == "NA", getfield.(outage_values[p_m_idx],:thermal_fuel))
                    end

                    temp_range = p_m_idx[fl_idx]

                    temp_cap = floor(Int,PSY.get_max_active_power(g))

                    if (length(temp_range)>1)
                        gen_idx = temp_range[1]
                        for (x,y) in zip(temp_range,getfield.(outage_values[temp_range],:capacity))
                            temp=0
                            if (temp<temp_cap<y)
                                gen_idx = x
                                break
                            else
                                temp = y
                            end
                        end
                        f_or = getfield(outage_values[gen_idx],:FOR)
                        mttr_hr = getfield(outage_values[gen_idx],:MTTR)

                        (??,??) = outage_to_rate((f_or,mttr_hr))

                    elseif (length(temp_range)==1)
                        gen_idx = temp_range[1]
                        
                        f_or = getfield(outage_values[gen_idx],:FOR)
                        mttr_hr = getfield(outage_values[gen_idx],:MTTR)

                        (??,??) = outage_to_rate((f_or,mttr_hr))
                    else
                        @warn "No outage information is available for $(PSY.get_name(g)) with a $(p_m) prime mover and $(fl) fuel type. Using nominal outage and recovery probabilities for this generator."
                        #?? = 0.0;
                        #?? = 1.0;
                    end

                elseif (gen_categories[idx] == "PowerSystems.HydroDispatch")
                    p_m = string(PSY.get_prime_mover(g))
                    p_m_idx = findall(x -> x == p_m, getfield.(outage_values,:prime_mover))

                    temp_cap = floor(Int,PSY.get_max_active_power(g))
                    
                    if (length(p_m_idx)>1)
                        for (x,y) in zip(p_m_idx,getfield.(outage_values[p_m_idx],:capacity))
                            temp=0
                            if (temp<temp_cap<y)
                                gen_idx = x

                                f_or = getfield(outage_values[gen_idx],:FOR)
                                mttr_hr = getfield(outage_values[gen_idx],:MTTR)

                                (??,??) = outage_to_rate((f_or,mttr_hr))
                                break
                            else
                                temp = y
                            end
                        end
                    end
                else
                    @warn "No outage information is available for $(PSY.get_name(g)) of type $(gen_categories[idx]). Using nominal outage and recovery probabilities for this generator."
                    #?? = 0.0;
                    #?? = 1.0;

                end

            else
                ext = PSY.get_ext(g)
                if (!(haskey(ext,"outage_probability") && haskey(ext,"recovery_probability")))
                    @warn "No outage information is available in ext field of $(PSY.get_name(g)) of type $(gen_categories[idx]). Using nominal outage and recovery probabilities for this generator."
                    #?? = 0.0;
                    #?? = 1.0;
                else
                    ?? = ext["outage_probability"];
                    ?? = ext["recovery_probability"];
                end
            end
            ??_gen[idx,:] = fill.(??,1,N); 
            ??_gen[idx,:] = fill.(??,1,N); 
        end
    end

    new_generators = PRAS.Generators{N,1,PRAS.Hour,PRAS.MW}(gen_names, get_generator_category.(gen), gen_cap_array , ??_gen ,??_gen);
        
    #######################################################
    # PRAS Storages
    # **TODO Future : time series for storage devices
    #######################################################
    @info "Processing Storages in PSY System... "

    stor=[];
    for i in 1: num_regions
        if (length(stors[i]) != 0)
            append!(stor,stors[i])
        end
    end

    if(length(stor) ==0)
        stor_names=String[];
    else
        stor_names = PSY.get_name.(stor);
    end

    stor_categories = string.(typeof.(stor));

    n_stor = length(stor_names);

    stor_charge_cap_array = Matrix{Int64}(undef, n_stor, N);
    stor_discharge_cap_array = Matrix{Int64}(undef, n_stor, N);
    stor_energy_cap_array = Matrix{Int64}(undef, n_stor, N);
    stor_chrg_eff_array = Matrix{Float64}(undef, n_stor, N);
    stor_dischrg_eff_array  = Matrix{Float64}(undef, n_stor, N);
    ??_stor = Matrix{Float64}(undef, n_stor, N);   
    ??_stor = Matrix{Float64}(undef, n_stor, N);

    for (idx,s) in enumerate(stor)
        stor_charge_cap_array[idx,:] = fill(floor(Int,getfield(PSY.get_input_active_power_limits(s), :max)),1,N);
        stor_discharge_cap_array[idx,:] = fill(floor(Int,getfield(PSY.get_output_active_power_limits(s), :max)),1,N);
        stor_energy_cap_array[idx,:] = fill(floor(Int,getfield(PSY.get_state_of_charge_limits(s),:max)),1,N);
        stor_chrg_eff_array[idx,:] = fill(getfield(PSY.get_efficiency(s), :in),1,N);
        stor_dischrg_eff_array[idx,:]  = fill.(getfield(PSY.get_efficiency(s), :out),1,N);

        if (~outage_flag)
            @warn "No outage information is available for $(PSY.get_name(s)) of type $(stor_categories[idx]). Using nominal outage and recovery probabilities for this generator."
            ?? = 0.0;
            ?? = 1.0;
        else
            ext = PSY.get_ext(s)
            if (!(haskey(ext,"outage_probability") && haskey(ext,"recovery_probability")))
                @warn "No outage information is available in ext field of $(PSY.get_name(s)) of type $(stor_categories[idx]). Using nominal outage and recovery probabilities for this generator."
                ?? = 0.0;
                ?? = 1.0;
            else
                ?? = ext["outage_probability"];
                ?? = ext["recovery_probability"];
            end
        end
        
        ??_stor[idx,:] = fill.(??,1,N); 
        ??_stor[idx,:] = fill.(??,1,N); 
    end
    
    stor_cryovr_eff = ones(n_stor,N);   # Not currently available/ defined in PowerSystems
    
    new_storage = PRAS.Storages{N,1,PRAS.Hour,PRAS.MW,PRAS.MWh}(stor_names,get_generator_category.(stor),
                                            stor_charge_cap_array,stor_discharge_cap_array,stor_energy_cap_array,
                                            stor_chrg_eff_array,stor_dischrg_eff_array, stor_cryovr_eff,
                                            ??_stor,??_stor);

    #######################################################
    # PRAS Generator Storages
    # **TODO Consider all combinations of HybridSystem (Currently only works for DER+ESS)
    #######################################################
    @info "Processing GeneratorStorages in PSY System... "

    gen_stor=[];
    for i in 1: num_regions
        if (length(gen_stors[i]) != 0)
            append!(gen_stor,gen_stors[i])
        end
    end
    
    if(length(gen_stor) == 0)
        gen_stor_names=String[];
    else
        gen_stor_names = PSY.get_name.(gen_stor);
    end

    gen_stor_categories = string.(typeof.(gen_stor)); 
    
    n_genstors = length(gen_stor_names);

    gen_stor_charge_cap_array = Matrix{Int64}(undef, n_genstors, N);
    gen_stor_discharge_cap_array = Matrix{Int64}(undef, n_genstors, N);
    gen_stor_enrgy_cap_array = Matrix{Int64}(undef, n_genstors, N);
    gen_stor_inflow_array = Matrix{Int64}(undef, n_genstors, N);
    gen_stor_gridinj_cap_array = Matrix{Int64}(undef, n_genstors, N);

    ??_genstors = Matrix{Float64}(undef, n_genstors, N);   
    ??_genstors = Matrix{Float64}(undef, n_genstors, N);  

    for (idx,g_s) in enumerate(gen_stor)
        if(typeof(g_s) ==PSY.HydroEnergyReservoir)
            if (PSY.has_time_series(g_s))
                if ("inflow" in PSY.get_name.(PSY.get_time_series_multiple(g_s)))
                    gen_stor_charge_cap_array[idx,:] = floor.(Int,get_forecast_values(first(PSY.get_time_series_multiple(g_s, name = "inflow")))
                                                       *PSY.get_inflow(g_s));
                    gen_stor_discharge_cap_array[idx,:] = floor.(Int,get_forecast_values(first(PSY.get_time_series_multiple(g_s, name = "inflow")))
                                                          *PSY.get_inflow(g_s));
                    gen_stor_inflow_array[idx,:] = floor.(Int,get_forecast_values(first(PSY.get_time_series_multiple(g_s, name = "inflow")))
                                                   *PSY.get_inflow(g_s));
                else
                    gen_stor_charge_cap_array[idx,:] = fill.(floor.(Int,PSY.get_inflow(g_s)),1,N);
                    gen_stor_discharge_cap_array[idx,:] = fill.(floor.(Int,PSY.get_inflow(g_s)),1,N);
                    gen_stor_inflow_array[idx,:] = fill.(floor.(Int,PSY.get_inflow(g_s)),1,N);
                end
                if ("storage_capacity" in PSY.get_name.(PSY.get_time_series_multiple(g_s)))
                    gen_stor_enrgy_cap_array[idx,:] = floor.(Int,get_forecast_values(first(PSY.get_time_series_multiple(g_s, name = "storage_capacity")))
                                                      *PSY.get_storage_capacity(g_s));
                else
                    gen_stor_enrgy_cap_array[idx,:] = fill.(floor.(Int,PSY.get_storage_capacity(g_s)),1,N);
                end
                if ("max_active_power" in PSY.get_name.(PSY.get_time_series_multiple(g_s)))
                    gen_stor_gridinj_cap_array[idx,:] = floor.(Int,get_forecast_values(first(PSY.get_time_series_multiple(g_s, name = "max_active_power")))
                                                        *PSY.get_max_active_power(g_s));
                else
                    gen_stor_gridinj_cap_array[idx,:] = fill.(floor.(Int,PSY.get_max_active_power(g_s)),1,N);
                end
            else
                gen_stor_charge_cap_array[idx,:] = fill.(floor.(Int,PSY.get_inflow(g_s)),1,N);
                gen_stor_discharge_cap_array[idx,:] = fill.(floor.(Int,PSY.get_inflow(g_s)),1,N);
                gen_stor_enrgy_cap_array[idx,:] = fill.(floor.(Int,PSY.get_storage_capacity(g_s)),1,N);
                gen_stor_inflow_array[idx,:] = fill.(floor.(Int,PSY.get_inflow(g_s)),1,N);
                gen_stor_gridinj_cap_array[idx,:] = fill.(floor.(Int,PSY.get_max_active_power(g_s)),1,N);
            end  
        else
            gen_stor_charge_cap_array[idx,:] = fill.(floor.(Int,getfield(PSY.get_input_active_power_limits(PSY.get_storage(g_s)), :max)),1,N);
            gen_stor_discharge_cap_array[idx,:] = fill.(floor.(Int,getfield(PSY.get_output_active_power_limits(PSY.get_storage(g_s)), :max)),1,N);
            gen_stor_enrgy_cap_array[idx,:] = fill.(floor.(Int,getfield(PSY.get_state_of_charge_limits(PSY.get_storage(g_s)), :max)),1,N); 
            gen_stor_gridinj_cap_array[idx,:] = fill.(floor.(Int,PSY.getfield(PSY.get_output_active_power_limits(g_s), :max)),1,N);
            
            if (PSY.has_time_series(PSY.get_renewable_unit(g_s)) && ("max_active_power" in PSY.get_name.(PSY.get_time_series_multiple(PSY.get_renewable_unit(g_s)))))
                gen_stor_inflow_array[idx,:] = floor.(Int,get_forecast_values(first(PSY.get_time_series_multiple(PSY.get_renewable_unit(g_s), name = "max_active_power")))
                                               *PSY.get_max_active_power(PSY.get_renewable_unit(g_s))); 
            else
                gen_stor_inflow_array[idx,:] = fill.(floor.(Int,PSY.get_max_active_power(PSY.get_renewable_unit(g_s))),1,N); 
            end
        end
        
        if (~outage_flag)
            if (typeof(g_s) ==PSY.HydroEnergyReservoir)
                p_m = string(PSY.get_prime_mover(g_s))
                p_m_idx = findall(x -> x == p_m, getfield.(outage_values,:prime_mover))

                temp_cap = floor(Int,PSY.get_max_active_power(g_s))
                
                if (length(p_m_idx)>1)
                    for (x,y) in zip(p_m_idx,getfield.(outage_values[p_m_idx],:capacity))
                        temp=0
                        if (temp<temp_cap<y)
                            gen_idx = x

                            f_or = getfield(outage_values[gen_idx],:FOR)
                            mttr_hr = getfield(outage_values[gen_idx],:MTTR)

                            (??,??) = outage_to_rate((f_or,mttr_hr))
                            break
                        else
                            temp = y
                        end
                    end
                end
            else
                @warn "No outage information is available for $(PSY.get_name(g_s)) of type $(gen_stor_categories[idx]). Using nominal outage and recovery probabilities for this generator."
                ?? = 0.0;
                ?? = 1.0;
            end

        else
            ext = PSY.get_ext(g_s)
            if (!(haskey(ext,"outage_probability") && haskey(ext,"recovery_probability")))
                @warn "No outage information is available in ext field of $(PSY.get_name(g_s)) of type $(gen_stor_categories[idx]). Using nominal outage and recovery probabilities for this generator."
                ?? = 0.0;
                ?? = 1.0;
            else
                ?? = ext["outage_probability"];
                ?? = ext["recovery_probability"];
            end
        end
        
        ??_genstors[idx,:] = fill.(??,1,N); 
        ??_genstors[idx,:] = fill.(??,1,N);
    end
    
    gen_stor_gridwdr_cap_array = zeros(Int64,n_genstors, N); # Not currently available/ defined in PowerSystems
    gen_stor_charge_eff = ones(n_genstors,N);                # Not currently available/ defined in PowerSystems
    gen_stor_discharge_eff = ones(n_genstors,N);             # Not currently available/ defined in PowerSystems
    gen_stor_cryovr_eff = ones(n_genstors,N);                # Not currently available/ defined in PowerSystems

    
    new_gen_stors = PRAS.GeneratorStorages{N,1,PRAS.Hour,PRAS.MW,PRAS.MWh}(gen_stor_names,get_generator_category.(gen_stor),
                                                    gen_stor_charge_cap_array, gen_stor_discharge_cap_array, gen_stor_enrgy_cap_array,
                                                    gen_stor_charge_eff, gen_stor_discharge_eff, gen_stor_cryovr_eff,
                                                    gen_stor_inflow_array, gen_stor_gridwdr_cap_array, gen_stor_gridinj_cap_array,
                                                    ??_genstors, ??_genstors);

    #######################################################
    # PRAS SystemModel
    #######################################################
    if (system_model=="Zonal")
    #######################################################
    # PRAS Lines 
    #######################################################
    @info "Collecting all inter regional lines in PSY System..."

    # Dictionary with topology mapping
        line = availability_flag ? 
        collect(PSY.get_components(PSY.Branch, sys, (x -> ~in(typeof(x), [PSY.TapTransformer, PSY.Transformer2W,PSY.PhaseShiftingTransformer]) && PSY.get_available(x)))) :
        collect(PSY.get_components(PSY.Branch, sys, x -> ~in(typeof(x), [PSY.TapTransformer, PSY.Transformer2W,PSY.PhaseShiftingTransformer])));

        mapping_dict = PSY.get_aggregation_topology_mapping(aggregation_topology,sys); # Dict with mapping from Areas to Bus_Names
        new_mapping_dict=Dict{String,Array{Int64,1}}(); 

        for key in keys(mapping_dict)
            push!(new_mapping_dict, key  => PSY.get_number.(mapping_dict[key]))
        end
        
        #######################################################
        # Finding the inter-regional lines and regions_from
        #######################################################
        regional_lines = []; 
        regions_from = [];
        for i in 1:length(line)
            for key in keys(mapping_dict)
                if(PSY.get_number(line[i].arc.from) in new_mapping_dict[key])
                    if(~(PSY.get_number(line[i].arc.to) in new_mapping_dict[key]))
                        push!(regional_lines,line[i])
                        push!(regions_from,key)
                    end
                end
            end
        end
        
        #######################################################
        # Finding the regions_to
        #######################################################
        n_lines = length(regional_lines);
        regions_to = [];
        for i in 1:n_lines
            for key in keys(mapping_dict)
                if(PSY.get_number(regional_lines[i].arc.to) in new_mapping_dict[key])
                    push!(regions_to,key)
                end
            end
        end
        
        #######################################################
        # If there are lines from region1 --> region3 and 
        # region3 --> region1; lines like these need to be grouped
        # to make interface_line_idxs
        #######################################################
        regions_tuple = [];
        for i in 1:length(regions_from)
            region_from_idx = findfirst(x->x==regions_from[i],region_names)
            region_to_idx = findfirst(x->x==regions_to[i],region_names)
            if (region_from_idx < region_to_idx)
                push!(regions_tuple,(regions_from[i],regions_to[i]))
            else
                push!(regions_tuple,(regions_to[i],regions_from[i]))
            end
        end

        temp_regions_tuple = unique(regions_tuple);
        interface_dict = Dict();

        for i in 1: length(temp_regions_tuple)
            temp = findall(x -> x == temp_regions_tuple[i], regions_tuple);
            push!(interface_dict, temp_regions_tuple[i] => (temp,length(temp)))
        end

        num_interfaces = length(temp_regions_tuple);
        sorted_regional_lines = [];
        interface_line_idxs = Array{UnitRange{Int64},1}(undef,num_interfaces);
        start_id = Array{Int64}(undef,num_interfaces); 
        for i in 1: num_interfaces
            for j in interface_dict[temp_regions_tuple[i]][1]
                push!(sorted_regional_lines, regional_lines[j])
            end
            i==1 ? start_id[i] = 1 : start_id[i] =start_id[i-1]+interface_dict[temp_regions_tuple[i-1]][2]
            interface_line_idxs[i] = range(start_id[i], length=interface_dict[temp_regions_tuple[i]][2])
        end
        
        @info "Processing all inter regional lines in PSY System..."
        line_names = PSY.get_name.(sorted_regional_lines);
        line_categories = string.(typeof.(sorted_regional_lines));
        
        line_forward_capacity_array = Matrix{Int64}(undef, n_lines, N);
        line_backward_capacity_array = Matrix{Int64}(undef, n_lines, N);

        ??_lines = Matrix{Float64}(undef, n_lines, N); # Not currently available/ defined in PowerSystems
        ??_lines = Matrix{Float64}(undef, n_lines, N); # Not currently available/ defined in PowerSystems
        for i in 1:n_lines
            line_forward_capacity_array[i,:] = fill.(floor.(Int,getfield(line_rating(sorted_regional_lines[i]),:forward_capacity)),1,N);
            line_backward_capacity_array[i,:] = fill.(floor.(Int,getfield(line_rating(sorted_regional_lines[i]),:backward_capacity)),1,N);

            ??_lines[i,:] .= 0.0; # Not currently available/ defined in PowerSystems # should change when we have this
            ??_lines[i,:] .= 1.0; # Not currently available/ defined in PowerSystems
        end
        
        new_lines = PRAS.Lines{N,1,PRAS.Hour,PRAS.MW}(line_names, line_categories, line_forward_capacity_array, line_backward_capacity_array, ??_lines ,??_lines);
        #######################################################
        # PRAS Interfaces
        #######################################################
        interface_regions_from = [findfirst(x->x==temp_regions_tuple[i][1],region_names) for i in 1:num_interfaces];
        interface_regions_to = [findfirst(x->x==temp_regions_tuple[i][2],region_names) for i in 1:num_interfaces];
        
        @info "Processing interfaces from inter regional lines in PSY System..."
        interface_forward_capacity_array = Matrix{Int64}(undef, num_interfaces, N);
        interface_backward_capacity_array = Matrix{Int64}(undef, num_interfaces, N);
        for i in 1:num_interfaces
            interface_forward_capacity_array[i,:] =  sum(line_forward_capacity_array[interface_line_idxs[i],:],dims=1)
            interface_backward_capacity_array[i,:] =  sum(line_backward_capacity_array[interface_line_idxs[i],:],dims=1)
        end

        new_interfaces = PRAS.Interfaces{N,PRAS.MW}(interface_regions_from, interface_regions_to, interface_forward_capacity_array, interface_backward_capacity_array);

        pras_system = PRAS.SystemModel(new_regions, new_interfaces, new_generators, region_gen_idxs, new_storage, region_stor_idxs, new_gen_stors,
                          region_genstor_idxs, new_lines,interface_line_idxs,my_timestamps);
    
    elseif (system_model =="Single-Node")
        load_vector = vec(sum(region_load,dims=1));
        pras_system = PRAS.SystemModel(new_generators, new_storage, new_gen_stors, my_timestamps, load_vector);
    else
        error("Unrecognized SystemModel; Please specify correctly if SystemModel is Single-Node or Zonal.")
    end
    @info "Successfully built a PRAS $(system_model) system of type $(typeof(pras_system))."
    return pras_system
end
#=
dup_uuids =[];
for h_s in PSY.get_components(PSY.HybridSystem, sys)
    h_s_subcomps = PSY._get_components(h_s)
    for subcomp in h_s_subcomps
        push!(dup_uuids,PSY.IS.get_uuid(subcomp))
    end
end
get_components(ThermalGen, sys, x -> get_uuid(x) ??? subcomponents)

h_s = PSY.get_components(PSY.HybridSystem, sys)
subcomponents =Set(PSY.IS.get_uuid.(PSY._get_components.(h_s)))
get_components(ThermalGen, sys, x -> get_uuid(x) ??? subcomponents)

dup_uuids = PSY.IS.get_uuid.([component for component in PSY._get_components.(PSY.get_components(PSY.HybridSystem, sys))])

=#